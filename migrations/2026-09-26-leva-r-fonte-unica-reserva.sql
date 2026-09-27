-- ============================================================
-- LEVA R: calendar_events vira fonte única de quando/status de uma
-- locação, e event_type/equipment_id não podem mais discordar
--
-- CONTEXTO
-- Item E2 do diagnóstico. Antes de aplicar, foi conferido por consulta
-- direta que hoje não existe nenhuma linha divergente: nenhuma locação
-- com data ou status diferente do seu evento de agenda, nenhum
-- event_type discordando do equipment_id, nenhuma locação sem evento
-- vinculado. Ou seja, esta migration só formaliza no banco uma
-- coerência que já existe na prática, sem precisar de nenhuma limpeza
-- de dados antes.
--
-- O QUE MUDA
-- 1) calendar_events.rental_id passa a ser único (relação 1 para 1,
--    já era assim na prática, agora é garantida pelo banco).
-- 2) event_type e equipment_id não podem mais divergir: hipro_1/
--    hipro_2 sempre com o equipamento correspondente, qualquer outro
--    tipo sempre sem equipamento. Como isso depende de olhar
--    equipments.code (outra tabela), é um trigger, não um check
--    simples.
-- 3) calendar_events vira a fonte de verdade de "quando" e "status":
--    ao mudar date_start ou status do evento de uma locação, rentals
--    é atualizado junto automaticamente. Nenhuma tela muda — o app
--    continua lendo e escrevendo como já escreve hoje — isso só
--    protege contra uma função futura que esqueça de atualizar as
--    duas tabelas.
-- 4) update_rental corrigida: ela já atualizava
--    calendar_events.equipment_id ao trocar o equipamento de uma
--    locação (EditarLocacaoModal permite isso), mas nunca atualizava
--    event_type junto — exatamente a divergência que o item 2 acima
--    passa a proibir. Sem esta correção, trocar o HIPRO de uma locação
--    existente quebraria com a trigger nova. Não foi encontrada
--    nenhuma linha já divergente hoje (conferido antes de aplicar);
--    isso teria acontecido na primeira troca de equipamento feita
--    depois desta migration, não antes.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Uma locação tem no máximo um evento de agenda vinculado
-- ------------------------------------------------------------
create unique index if not exists calendar_events_rental_uidx
  on calendar_events(rental_id) where rental_id is not null;

-- ------------------------------------------------------------
-- 2. event_type coerente com equipment_id
-- ------------------------------------------------------------
create or replace function public.validar_equipamento_coerente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_equipment_code equipment_code_type;
begin
  if new.event_type in ('hipro_1', 'hipro_2') then
    if new.equipment_id is null then
      raise exception 'Evento do tipo % precisa de um equipamento vinculado.', new.event_type;
    end if;
    select code into v_equipment_code from equipments where id = new.equipment_id;
    if v_equipment_code::text is distinct from new.event_type::text then
      raise exception 'Evento do tipo % não pode apontar para o equipamento %.', new.event_type, v_equipment_code;
    end if;
  elsif new.equipment_id is not null then
    raise exception 'Evento do tipo % não pode ter equipamento vinculado.', new.event_type;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validar_equipamento_coerente on calendar_events;
create trigger trg_validar_equipamento_coerente
  before insert or update of event_type, equipment_id on calendar_events
  for each row execute function public.validar_equipamento_coerente();

-- ------------------------------------------------------------
-- 3. calendar_events como fonte de verdade: rentals acompanha sozinho
-- ------------------------------------------------------------
create or replace function public.sync_rental_from_calendar_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.rental_id is not null
     and (new.date_start is distinct from old.date_start or new.status is distinct from old.status) then
    update rentals
       set event_date = new.date_start,
           status = new.status
     where id = new.rental_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_rental_from_calendar_event on calendar_events;
create trigger trg_sync_rental_from_calendar_event
  after update of date_start, status on calendar_events
  for each row execute function public.sync_rental_from_calendar_event();

-- ------------------------------------------------------------
-- 4. update_rental agora deriva event_type do equipamento novo,
--    exatamente como create_rental já fazia
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
