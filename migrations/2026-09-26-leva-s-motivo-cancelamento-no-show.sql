-- ============================================================
-- LEVA S: motivo de cancelamento vira coluna consultável, e
-- "não compareceu" (no-show) passa a existir como marcação distinta
-- de um cancelamento comum
--
-- CONTEXTO
-- Item E6 do diagnóstico. Hoje o motivo de cancelamento só existe
-- dentro do jsonb de auditoria (movimentacoes.detalhes->>'motivo'),
-- não é uma coluna consultável. E "não compareceu" não existe: tudo
-- vira só 'cancelada'.
--
-- Também foi encontrado, ao investigar, que existem HOJE três
-- caminhos diferentes para cancelar algo, e só um deles (a função
-- cancelar_agendamento, usada pela ficha do cliente) aplica as regras
-- de negócio corretas (bloquear se já foi paga, taxa paga vira
-- perdida). Os outros dois cancelam "por fora":
--   - EditarEventoModal.tsx fazia update direto na tabela
--     calendar_events, sem passar pela função nenhuma.
--   - EditarLocacaoModal.tsx deixava escolher 'cancelada' no dropdown
--     de status, que ia para a função update_rental — que também não
--     aplica nenhuma dessas regras.
-- Esta migration fecha os dois caminhos "por fora", forçando todo
-- cancelamento a passar por cancelar_agendamento.
--
-- O QUE MUDA
-- 1) calendar_events e rentals ganham cancellation_reason (texto) e
--    no_show (boolean, default false).
-- 2) O trigger de sincronização da leva R (sync_rental_from_calendar_event)
--    passa a copiar essas duas colunas de calendar_events para rentals
--    também, do mesmo jeito que já copia date_start/status.
-- 3) cancelar_agendamento ganha o parâmetro p_no_show e grava as duas
--    colunas novas em calendar_events (rentals é sincronizado sozinho
--    pelo trigger do item 2).
-- 4) reativar_agendamento limpa as duas colunas ao reativar (para não
--    ficar "não compareceu" gravado num agendamento que voltou a
--    valer).
-- 5) Nova função cancelar_locacao(p_rental_id, p_motivo, p_no_show):
--    atalho para quem só tem o id da locação (EditarLocacaoModal), acha
--    o evento de agenda vinculado e delega para cancelar_agendamento —
--    sem duplicar nenhuma regra.
-- 6) update_rental passa a recusar uma mudança de status PARA
--    'cancelada' (uma locação que já estava cancelada continua podendo
--    ser salva normalmente, sem erro, contanto que o status não esteja
--    mudando agora). A mensagem de erro aponta para cancelar_locacao.
-- 7) agendamentos_do_cliente (usada pela ficha do cliente) passa a
--    devolver cancellation_reason e no_show também, para a tela poder
--    mostrar.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Colunas novas
-- ------------------------------------------------------------
alter table public.calendar_events
  add column if not exists cancellation_reason text,
  add column if not exists no_show boolean not null default false;

alter table public.rentals
  add column if not exists cancellation_reason text,
  add column if not exists no_show boolean not null default false;

comment on column public.calendar_events.cancellation_reason is
  'Motivo do cancelamento, preenchido por cancelar_agendamento (leva S). Fica null enquanto o agendamento não foi cancelado, e é limpo de novo por reativar_agendamento.';
comment on column public.calendar_events.no_show is
  'true = cancelado porque o cliente não compareceu, distinto de um cancelamento comum (leva S). Só é gravado por cancelar_agendamento.';

-- ------------------------------------------------------------
-- 2. Trigger da leva R passa a sincronizar também estas duas colunas
-- ------------------------------------------------------------
create or replace function public.sync_rental_from_calendar_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.rental_id is not null
     and (new.date_start is distinct from old.date_start
          or new.status is distinct from old.status
          or new.cancellation_reason is distinct from old.cancellation_reason
          or new.no_show is distinct from old.no_show) then
    update rentals
       set event_date = new.date_start,
           status = new.status,
           cancellation_reason = new.cancellation_reason,
           no_show = new.no_show
     where id = new.rental_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_rental_from_calendar_event on calendar_events;
create trigger trg_sync_rental_from_calendar_event
  after update of date_start, status, cancellation_reason, no_show on calendar_events
  for each row execute function public.sync_rental_from_calendar_event();

-- ------------------------------------------------------------
-- 3. cancelar_agendamento ganha p_no_show e grava as colunas novas
-- ------------------------------------------------------------
create or replace function public.cancelar_agendamento(
  p_event_id uuid,
  p_motivo text default null,
  p_no_show boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental_id uuid;
  v_status event_status_type;
  v_taxa text;
  v_descricao text;
  v_pago boolean;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para cancelar agendamentos.';
  end if;

  select rental_id, status, taxa_status into v_rental_id, v_status, v_taxa
    from calendar_events where id = p_event_id;

  if v_status is null then
    raise exception 'Agendamento não encontrado.';
  end if;
  if v_status = 'cancelada' then
    raise exception 'Este agendamento já está cancelado.';
  end if;

  if v_rental_id is not null then
    select pago into v_pago from rentals where id = v_rental_id;
    if v_pago then
      raise exception 'Esta locação já foi paga. Desfaça o pagamento antes de cancelar, para o caixa não ficar com receita de algo cancelado.';
    end if;
  end if;

  v_descricao := public.descrever_registro('calendar_events', p_event_id);

  update calendar_events
     set status = 'cancelada',
         cancellation_reason = nullif(trim(p_motivo), ''),
         no_show = coalesce(p_no_show, false)
   where id = p_event_id;
  -- rentals.status/cancellation_reason/no_show são sincronizados sozinhos
  -- pelo trigger trg_sync_rental_from_calendar_event (leva R + S).

  if v_taxa = 'paga' then
    update calendar_events set taxa_status = 'perdida' where id = p_event_id;
    perform public.registrar_movimentacao(
      'taxa_perdida', 'calendar_events', p_event_id, v_descricao,
      jsonb_build_object('motivo', 'agendamento cancelado após a taxa ter sido paga')
    );
  end if;

  -- Leva O: taxa perdida deixa de contar como crédito, então o saldo da
  -- locação (se houver) precisa ser recalculado.
  if v_rental_id is not null then
    perform public.recalcular_pagamento_locacao(v_rental_id);
  end if;

  perform public.registrar_movimentacao(
    'cancelado', 'calendar_events', p_event_id, v_descricao,
    jsonb_build_object(
      'motivo', coalesce(nullif(trim(p_motivo), ''), 'não informado'),
      'no_show', coalesce(p_no_show, false),
      'taxa', coalesce(v_taxa, 'nao_aplica'),
      'status_anterior', v_status
    )
  );
end;
$$;

grant execute on function public.cancelar_agendamento to authenticated;

-- ------------------------------------------------------------
-- 4. reativar_agendamento limpa motivo/no_show ao reativar
-- ------------------------------------------------------------
create or replace function public.reativar_agendamento(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental_id uuid;
  v_equipment_id uuid;
  v_data date;
  v_ocupante text;
  v_taxa text;
  v_taxa_transacao uuid;
  v_status_anterior event_status_type;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para reativar agendamentos.';
  end if;

  select rental_id, equipment_id, date_start, taxa_status, taxa_transaction_id
    into v_rental_id, v_equipment_id, v_data, v_taxa, v_taxa_transacao
    from calendar_events where id = p_event_id and status = 'cancelada';

  if v_data is null then
    raise exception 'Agendamento não encontrado ou não está cancelado.';
  end if;

  if v_equipment_id is not null then
    select coalesce(c.name, ev.title) into v_ocupante
      from calendar_events ev
      left join clients c on c.id = ev.client_id
     where ev.equipment_id = v_equipment_id
       and ev.status <> 'cancelada'
       and ev.id <> p_event_id
       and daterange(ev.date_start, ev.date_end, '[]') && daterange(v_data, v_data, '[]')
     limit 1;

    if v_ocupante is not null then
      raise exception 'Não dá para reativar: o equipamento já foi reservado em % para %. Reagende para outra data.',
        to_char(v_data, 'DD/MM/YYYY'), v_ocupante;
    end if;
  end if;

  select (detalhes->>'status_anterior')::event_status_type
    into v_status_anterior
    from movimentacoes
   where entidade = 'calendar_events' and entidade_id = p_event_id and acao = 'cancelado'
   order by ocorrido_em desc
   limit 1;

  if v_status_anterior is null or v_status_anterior = 'cancelada' then
    v_status_anterior := 'confirmada';
  end if;

  update calendar_events
     set status = v_status_anterior,
         confirmed = false,
         cancellation_reason = null,
         no_show = false
   where id = p_event_id;
  if v_rental_id is not null then
    update rentals
       set status = v_status_anterior,
           cancellation_reason = null,
           no_show = false
     where id = v_rental_id;
  end if;

  if v_taxa = 'perdida' and v_taxa_transacao is not null then
    update calendar_events set taxa_status = 'paga' where id = p_event_id;
    perform public.registrar_movimentacao(
      'taxa_paga', 'calendar_events', p_event_id,
      public.descrever_registro('calendar_events', p_event_id),
      jsonb_build_object('motivo', 'agendamento reativado; a taxa paga volta a valer como crédito')
    );
  end if;

  -- Leva O: taxa que voltou a valer como crédito muda o saldo da locação.
  if v_rental_id is not null then
    perform public.recalcular_pagamento_locacao(v_rental_id);
  end if;

  perform public.registrar_movimentacao(
    'editado', 'calendar_events', p_event_id,
    public.descrever_registro('calendar_events', p_event_id),
    jsonb_build_object('acao_detalhada', 'agendamento reativado', 'status_restaurado', v_status_anterior)
  );
end;
$$;

grant execute on function public.reativar_agendamento to authenticated;

-- ------------------------------------------------------------
-- 5. cancelar_locacao: atalho para quem só tem o id da locação
-- ------------------------------------------------------------
create or replace function public.cancelar_locacao(
  p_rental_id uuid,
  p_motivo text default null,
  p_no_show boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id from calendar_events where rental_id = p_rental_id;
  if v_event_id is null then
    raise exception 'Locação sem evento de agenda vinculado (id %).', p_rental_id;
  end if;
  perform public.cancelar_agendamento(v_event_id, p_motivo, p_no_show);
end;
$$;

grant execute on function public.cancelar_locacao to authenticated;

-- ------------------------------------------------------------
-- 6. update_rental recusa mudar o status PARA cancelada por fora
-- ------------------------------------------------------------
create or replace function public.update_rental(
  p_rental_id uuid,
  p_equipment_id uuid,
  p_event_date date,
  p_shots integer,
  p_calculated_value numeric,
  p_payment_method payment_method_type,
  p_status event_status_type,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction_id uuid;
  v_client_id uuid;
  v_old_date date;
  v_old_status event_status_type;
  v_old_value numeric;
  v_descricao text;
  v_equipment_code equipment_code_type;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para editar locações';
  end if;

  select transaction_id, client_id, event_date, status, calculated_value
    into v_transaction_id, v_client_id, v_old_date, v_old_status, v_old_value
    from rentals where id = p_rental_id;

  if v_client_id is null then
    raise exception 'Locação não encontrada (id %).', p_rental_id;
  end if;

  -- Leva S: cancelar por aqui pulava as regras de negócio (bloquear se
  -- já foi paga, taxa paga virar perdida, motivo/no-show). Uma locação
  -- que já estava cancelada continua podendo ser salva normalmente
  -- (outros campos), só a TRANSIÇÃO para cancelada é que é bloqueada.
  if p_status = 'cancelada' and v_old_status is distinct from 'cancelada' then
    raise exception 'Para cancelar uma locação, use o botão "Cancelar locação" (motivo e não comparecimento ficam registrados). Não é possível cancelar por aqui.';
  end if;

  select code into v_equipment_code from equipments where id = p_equipment_id;
  if v_equipment_code is null then
    raise exception 'Equipamento não encontrado (id %).', p_equipment_id;
  end if;

  update rentals
  set equipment_id = p_equipment_id,
      event_date = p_event_date,
      shots = p_shots,
      calculated_value = p_calculated_value,
      payment_method = p_payment_method,
      status = p_status,
      notes = p_notes,
      rescheduled = rescheduled or (v_old_date is not null and v_old_date <> p_event_date)
  where id = p_rental_id;

  if v_transaction_id is not null then
    update transactions
    set amount = p_calculated_value,
        date = p_event_date,
        payment_method = p_payment_method
    where id = v_transaction_id;
  end if;

  update calendar_events
  set event_type = v_equipment_code::text::calendar_event_type,
      equipment_id = p_equipment_id,
      date_start = p_event_date,
      date_end = p_event_date,
      value = p_calculated_value,
      status = p_status
  where rental_id = p_rental_id;

  v_descricao := public.descrever_registro('rentals', p_rental_id);

  if v_old_date is distinct from p_event_date then
    perform public.registrar_movimentacao(
      'reagendado', 'rentals', p_rental_id, v_descricao,
      jsonb_build_object(
        'data_antiga', to_char(v_old_date, 'DD/MM/YYYY'),
        'data_nova',   to_char(p_event_date, 'DD/MM/YYYY')
      )
    );
  elsif v_old_status is distinct from p_status then
    perform public.registrar_movimentacao(
      case p_status
        when 'cancelada' then 'cancelado'
        when 'confirmada' then 'confirmado'
        else 'editado'
      end,
      'rentals', p_rental_id, v_descricao,
      jsonb_build_object(
        'status_antigo', v_old_status::text,
        'status_novo',   p_status::text
      )
    );
  elsif v_old_value is distinct from p_calculated_value then
    perform public.registrar_movimentacao(
      'editado', 'rentals', p_rental_id, v_descricao,
      jsonb_build_object(
        'valor_antigo', round(coalesce(v_old_value, 0), 2),
        'valor_novo',   round(coalesce(p_calculated_value, 0), 2)
      )
    );
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 7. agendamentos_do_cliente devolve as duas colunas novas
-- ------------------------------------------------------------
drop function if exists public.agendamentos_do_cliente(uuid);

create or replace function public.agendamentos_do_cliente(p_client_id uuid)
returns table (
  event_id uuid,
  rental_id uuid,
  equipamento text,
  data date,
  status text,
  confirmado boolean,
  valor numeric,
  disparos integer,
  situacao text,
  taxa_status text,
  taxa_valor numeric,
  pago boolean,
  pago_em date,
  cancellation_reason text,
  no_show boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    ev.id,
    ev.rental_id,
    coalesce(eq.name, ev.title),
    ev.date_start,
    ev.status::text,
    ev.confirmed,
    coalesce(r.calculated_value, ev.value),
    r.shots,
    case
      when ev.status = 'cancelada'  then 'cancelado'
      when ev.status = 'realizada'  then 'realizado'
      when ev.confirmed             then 'confirmado'
      else 'agendado'
    end,
    ev.taxa_status,
    ev.taxa_valor,
    coalesce(r.pago, false),
    r.pago_em,
    ev.cancellation_reason,
    ev.no_show
  from calendar_events ev
  left join equipments eq on eq.id = ev.equipment_id
  left join rentals r on r.id = ev.rental_id
  where ev.client_id = p_client_id
  order by ev.date_start desc;
$$;

grant execute on function public.agendamentos_do_cliente to authenticated;
