-- ============================================================
-- LEVA Z: deslocamento também pode ser lançado ANTES da locação
-- existir, na própria pré-reserva
--
-- CONTEXTO: o deslocamento (leva O) só existia em `rentals`, então só
-- dava para lançar depois que a locação já tinha sido criada/finalizada
-- (disparos contados). Mas o cliente pode pagar o deslocamento
-- adiantado, ainda na pré-reserva ("Agendar sem disparos"), exatamente
-- o mesmo problema que o contrato já tinha (leva Y): um valor que
-- precisa poder ser registrado ANTES de existir uma linha em `rentals`.
--
-- Esta leva: (1) calendar_events ganha km_ida/valor_deslocamento, iguais
-- aos de rentals; (2) nova RPC definir_deslocamento_reserva, para
-- lançar/editar isso numa pré-reserva ainda não finalizada;
-- (3) finalize_rental_reservation passa a herdar esses dois campos da
-- pré-reserva para a locação recém-criada, para não perder o que já foi
-- lançado quando o procedimento acontece e a reserva é finalizada.
-- ============================================================

alter table public.calendar_events add column if not exists km_ida numeric(8,2);
alter table public.calendar_events add column if not exists valor_deslocamento numeric(10,2) not null default 0;

comment on column public.calendar_events.km_ida is
  'Km de ida até o local do procedimento, só para pré-reservas (leva Z) — igual a rentals.km_ida. Ao finalizar a reserva, este valor é copiado para a locação recém-criada.';
comment on column public.calendar_events.valor_deslocamento is
  'Ajuda de custo de deslocamento paga pelo cliente, lançável já na pré-reserva (leva Z), antes de a locação existir. Igual a rentals.valor_deslocamento, com o mesmo cálculo (R$ 50 a cada 50km de ida e volta).';

create or replace function public.definir_deslocamento_reserva(
  p_event_id uuid,
  p_km_ida numeric,
  p_valor_deslocamento numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para alterar agendamentos.';
  end if;
  if p_valor_deslocamento is not null and p_valor_deslocamento < 0 then
    raise exception 'O valor de deslocamento não pode ser negativo.';
  end if;

  update calendar_events
     set km_ida = p_km_ida,
         valor_deslocamento = coalesce(p_valor_deslocamento, 0)
   where id = p_event_id
     and rental_id is null
     and status = 'pre_reserva';

  if not found then
    raise exception 'Pré-reserva não encontrada (já pode ter sido finalizada ou cancelada).';
  end if;

  perform public.registrar_movimentacao(
    'editado', 'calendar_events', p_event_id,
    public.descrever_registro('calendar_events', p_event_id),
    jsonb_build_object('acao_detalhada', 'deslocamento definido (pré-reserva)', 'km_ida', p_km_ida, 'valor_deslocamento', p_valor_deslocamento)
  );
end;
$$;

grant execute on function public.definir_deslocamento_reserva to authenticated;

-- finalize_rental_reservation passa a ler km_ida/valor_deslocamento da
-- pré-reserva e gravar os dois já na locação recém-criada, para o que
-- foi lançado antes não se perder ao finalizar.
create or replace function public.finalize_rental_reservation(
  p_calendar_event_id uuid,
  p_shots integer,
  p_calculated_value numeric,
  p_payment_method payment_method_type,
  p_notes text default null,
  p_pix_conta text default null,
  p_pago boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental_id uuid;
  v_transaction_id uuid;
  v_category_id uuid;
  v_client_id uuid;
  v_equipment_id uuid;
  v_event_date date;
  v_client_name text;
  v_is_mentoria boolean;
  v_km_ida numeric;
  v_valor_deslocamento numeric;
  v_created_by uuid := auth.uid();
  v_pix_conta text;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para finalizar locações';
  end if;

  select client_id, equipment_id, date_start, is_mentoria, km_ida, valor_deslocamento
    into v_client_id, v_equipment_id, v_event_date, v_is_mentoria, v_km_ida, v_valor_deslocamento
  from calendar_events
  where id = p_calendar_event_id and rental_id is null and status = 'pre_reserva';

  if v_client_id is null then
    raise exception 'Reserva não encontrada, já finalizada, ou sem cliente vinculado.';
  end if;
  if v_equipment_id is null then
    raise exception 'Esta reserva não está vinculada a um equipamento HIPRO.';
  end if;

  select name into v_client_name from clients where id = v_client_id;

  if coalesce(v_is_mentoria, false) then
    select id into v_category_id from categories where type = 'entrada' and is_default = true and name ilike 'Mentoria%' limit 1;
    if v_category_id is null then
      raise exception 'Categoria "Mentoria" não encontrada (foi renomeada ou removida?). Ajuste o cadastro de categorias antes de finalizar a mentoria.';
    end if;
  else
    select id into v_category_id from categories where type = 'entrada' and is_default = true and name ilike 'Loca%' limit 1;
    if v_category_id is null then
      raise exception 'Categoria "Locação" não encontrada (foi renomeada ou removida?). Ajuste o cadastro de categorias antes de finalizar a reserva.';
    end if;
  end if;

  insert into rentals (client_id, equipment_id, event_date, shots, calculated_value, payment_method, notes, created_by, km_ida, valor_deslocamento)
  values (v_client_id, v_equipment_id, v_event_date, p_shots, p_calculated_value, p_payment_method, p_notes, v_created_by, v_km_ida, coalesce(v_valor_deslocamento, 0))
  returning id into v_rental_id;

  if p_pago then
    insert into transactions (type, category_id, description, amount, payment_method, date, scope, client_id, rental_id, created_by)
    values (
      'entrada',
      v_category_id,
      (case when coalesce(v_is_mentoria, false) then 'Mentoria HIPRO - ' else 'Locação HIPRO - ' end) || coalesce(v_client_name, ''),
      p_calculated_value, p_payment_method, v_event_date, 'harmonize', v_client_id, v_rental_id, v_created_by
    )
    returning id into v_transaction_id;

    v_pix_conta := case when p_payment_method = 'pix' then coalesce(p_pix_conta, 'harmonize') else null end;

    insert into rental_payments (rental_id, forma, valor, data, pix_conta, transaction_id, created_by)
    values (v_rental_id, p_payment_method, p_calculated_value, v_event_date, v_pix_conta, v_transaction_id, v_created_by);

    update rentals set transaction_id = v_transaction_id where id = v_rental_id;
    -- pago / pago_em: preenchidos automaticamente pelo trigger de
    -- rental_payments (ver nota da leva O sobre o bug corrigido aqui).
  end if;

  update calendar_events
  set status = 'confirmada',
      value = p_calculated_value,
      rental_id = v_rental_id,
      notes = coalesce(p_notes, notes)
  where id = p_calendar_event_id;

  update clients set stage = 'cliente' where id = v_client_id and stage <> 'cliente';

  return v_rental_id;
end;
$$;

grant execute on function public.finalize_rental_reservation(uuid, integer, numeric, payment_method_type, text, text, boolean) to authenticated;
