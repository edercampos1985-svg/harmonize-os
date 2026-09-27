-- ============================================================
-- LEVA T: manutenção do equipamento passa a bloquear a agenda
--
-- CONTEXTO
-- Item E3 do diagnóstico. equipments.status existe desde sempre (coluna
-- texto, default 'ativo'), mas não tem nenhuma UI para mudar de valor e
-- nada no banco olha para ele — ou seja, hoje ele não faz literalmente
-- nada. Esta leva fecha as duas pontas: dá um jeito de marcar um
-- equipamento em manutenção (com motivo), e faz esse status realmente
-- bloquear reservas novas.
--
-- O QUE MUDA
-- 1) equipments ganha status_motivo (texto) e status_desde (quando
--    mudou pela última vez), e o status passa a ser restrito a 'ativo'
--    ou 'manutencao' (constraint).
-- 2) Nova função definir_status_equipamento(p_equipment_id, p_status,
--    p_motivo): troca o status e registra em movimentacoes.
-- 3) validar_equipamento_coerente (leva R) passa a recusar criar ou
--    trocar um evento para um equipamento em manutenção. Importante: só
--    bloqueia quando o equipamento está de fato MUDANDO (reserva nova,
--    ou troca de equipamento numa locação existente) — uma locação já
--    marcada naquele equipamento continua editável normalmente (valor,
--    data, forma de pagamento etc.), só não pode ser criada nem trocada
--    para lá enquanto durar a manutenção.
-- 4) reativar_agendamento passa a recusar reativar um agendamento
--    cancelado se o equipamento dele estiver em manutenção agora (podia
--    estar ativo quando foi cancelado).
-- 5) movimentacoes.acao ganha 'manutencao_iniciada' e
--    'manutencao_finalizada' na lista de ações permitidas.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Colunas novas e status restrito
-- ------------------------------------------------------------
alter table public.equipments
  add column if not exists status_motivo text,
  add column if not exists status_desde timestamptz;

alter table public.equipments drop constraint if exists equipments_status_check;
alter table public.equipments
  add constraint equipments_status_check check (status in ('ativo', 'manutencao'));

comment on column public.equipments.status_motivo is
  'Motivo da manutenção, preenchido por definir_status_equipamento (leva T). Null quando status = ativo.';
comment on column public.equipments.status_desde is
  'Quando o status mudou pela última vez (leva T).';

-- ------------------------------------------------------------
-- 2. movimentacoes.acao ganha as duas ações novas
-- ------------------------------------------------------------
alter table public.movimentacoes drop constraint if exists movimentacoes_acao_check;
alter table public.movimentacoes
  add constraint movimentacoes_acao_check check (acao in (
    'criado', 'editado', 'confirmado', 'desconfirmado',
    'reagendado', 'cancelado', 'excluido',
    'realizado', 'realizacao_desfeita',
    'pago', 'pagamento_desfeito',
    'taxa_paga', 'taxa_perdida', 'taxa_isenta', 'taxa_pendente',
    'pedido_confirmacao_enviado',
    'manutencao_iniciada', 'manutencao_finalizada'
  ));

-- ------------------------------------------------------------
-- 3. definir_status_equipamento
-- ------------------------------------------------------------
create or replace function public.definir_status_equipamento(
  p_equipment_id uuid,
  p_status text,
  p_motivo text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
  v_status_atual text;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para alterar o status de equipamentos.';
  end if;

  if p_status not in ('ativo', 'manutencao') then
    raise exception 'Status inválido: %. Use ''ativo'' ou ''manutencao''.', p_status;
  end if;

  select name, status into v_nome, v_status_atual from equipments where id = p_equipment_id;
  if v_nome is null then
    raise exception 'Equipamento não encontrado (id %).', p_equipment_id;
  end if;

  if v_status_atual = p_status then
    return;
  end if;

  update equipments
     set status = p_status,
         status_motivo = case when p_status = 'manutencao' then nullif(trim(p_motivo), '') else null end,
         status_desde = now()
   where id = p_equipment_id;

  perform public.registrar_movimentacao(
    case p_status when 'manutencao' then 'manutencao_iniciada' else 'manutencao_finalizada' end,
    'equipments', p_equipment_id, 'Equipamento ' || v_nome,
    jsonb_build_object('motivo', coalesce(nullif(trim(p_motivo), ''), 'não informado'))
  );
end;
$$;

grant execute on function public.definir_status_equipamento to authenticated;

-- ------------------------------------------------------------
-- 4. validar_equipamento_coerente passa a olhar para o status
-- ------------------------------------------------------------
create or replace function public.validar_equipamento_coerente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_equipment_code equipment_code_type;
  v_equipment_status text;
begin
  if new.event_type in ('hipro_1', 'hipro_2') then
    if new.equipment_id is null then
      raise exception 'Evento do tipo % precisa de um equipamento vinculado.', new.event_type;
    end if;
    select code, status into v_equipment_code, v_equipment_status from equipments where id = new.equipment_id;
    if v_equipment_code::text is distinct from new.event_type::text then
      raise exception 'Evento do tipo % não pode apontar para o equipamento %.', new.event_type, v_equipment_code;
    end if;
    -- Leva T: só bloqueia quando o equipamento está de fato mudando
    -- (reserva nova, ou troca de equipamento numa locação existente).
    -- old é nulo num insert, então "is distinct from" já dá certo nos
    -- dois casos sem precisar checar tg_op à parte.
    if v_equipment_status = 'manutencao'
       and new.status <> 'cancelada'
       and new.equipment_id is distinct from old.equipment_id then
      raise exception 'Este equipamento está em manutenção no momento. Não é possível reservar ou mudar para ele até o status voltar a ativo.';
    end if;
  elsif new.equipment_id is not null then
    raise exception 'Evento do tipo % não pode ter equipamento vinculado.', new.event_type;
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- 5. reativar_agendamento recusa reativar num equipamento em manutenção
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
  v_equipment_status text;
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
    select status into v_equipment_status from equipments where id = v_equipment_id;
    if v_equipment_status = 'manutencao' then
      raise exception 'Não dá para reativar: o equipamento está em manutenção no momento.';
    end if;

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
