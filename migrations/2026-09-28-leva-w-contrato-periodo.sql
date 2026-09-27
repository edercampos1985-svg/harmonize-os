-- ============================================================
-- LEVA W: campos para o contrato de locação (CPF/CNPJ do cliente,
-- número de série e registro ANVISA do equipamento) + suporte a
-- locação de período (mais de um dia), com a mesma proteção contra
-- duplo-agendamento que já existe pra reserva de um dia só.
--
-- CONTEXTO: o modelo de contrato que a operação já usa fora do
-- sistema exige CPF/CNPJ do contratante e número de série do
-- equipamento — sem isso não dá pra gerar o contrato pelo sistema.
-- O próprio modelo mostra um caso real de locação por período (3
-- dias), então rentals precisa saber guardar isso — calendar_events
-- já tinha date_start/date_end desde sempre (a exclusion constraint
-- no_equipment_double_booking já usa daterange dos dois), só nunca
-- eram usados como intervalo de verdade: create_rental/update_rental
-- sempre gravavam date_start = date_end. Por isso a proteção contra
-- conflito nos dias do meio de um período não precisa de nenhuma
-- mudança na constraint, só as funções passarem a gravar um
-- date_end diferente quando for informado.
--
-- Período continua sendo exceção, não a regra: o campo novo é
-- opcional e só existe no fluxo de "Nova locação" direto (calculadora
-- em modo criação) — a pré-reserva feita clicando num dia específico
-- da Agenda (ReservarHiproModal) continua só de um dia, porque nasce
-- justamente de "clicar num dia", não de escolher um intervalo.
-- ============================================================

alter table public.clients add column if not exists document text;
comment on column public.clients.document is
  'CPF ou CNPJ do contratante, texto livre sem validação rígida de formato (leva W). Usado na geração do contrato de locação. Nulo = ainda não informado.';

alter table public.equipments add column if not exists serial_number text;
alter table public.equipments add column if not exists anvisa_registro text;
comment on column public.equipments.serial_number is
  'Número de série físico do aparelho (leva W), usado na geração do contrato de locação. Diferente de equipments.code (hipro_1/hipro_2, identidade lógica fixa) — este é o número gravado no aparelho de verdade, pode mudar se o aparelho for trocado.';
comment on column public.equipments.anvisa_registro is
  'Número de registro ANVISA do equipamento (leva W), usado na geração do contrato de locação.';

alter table public.rentals add column if not exists event_date_end date;
alter table public.rentals drop constraint if exists rentals_event_date_end_check;
alter table public.rentals add constraint rentals_event_date_end_check
  check (event_date_end is null or event_date_end >= event_date);
comment on column public.rentals.event_date_end is
  'Data final da locação quando ela cobre mais de um dia (leva W). Nulo = locação de um dia só (o padrão; event_date cobre tudo sozinho). Espelha calendar_events.date_end do evento vinculado.';

-- create_rental ganha p_event_date_end (leva W). Assinatura muda (novo
-- parâmetro no fim, default null = comportamento antigo intacto), por
-- isso o drop explícito antes do create or replace — create or replace
-- não substitui quando a lista de parâmetros muda, e o grant sem lista
-- de tipos fica ambíguo entre as versões (mesmo bug de sempre, já visto
-- em cancelar_agendamento e definir_status_equipamento). Um "drop
-- function" com uma lista de tipos fixa só cobre UMA assinatura antiga
-- específica — como esta função já mudou de assinatura mais de uma vez
-- no histórico do projeto, pode sobrar mais de uma versão velha no
-- banco. Por isso o bloco abaixo descobre e apaga TODAS as versões de
-- create_rental que existirem, seja qual for a assinatura, antes de
-- recriar a função.
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_rental'
  loop
    execute format('drop function %s', r.sig);
  end loop;
end $$;

create or replace function public.create_rental(
  p_client_id uuid,
  p_equipment_id uuid,
  p_event_date date,
  p_shots integer,
  p_calculated_value numeric,
  p_payment_method payment_method_type,
  p_notes text default null,
  p_pago boolean default true,
  p_pix_conta text default null,
  p_event_date_end date default null
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
  v_equipment_code equipment_code_type;
  v_client_name text;
  v_created_by uuid := auth.uid();
  v_parceiro boolean;
  v_taxa_status text;
  v_taxa_valor numeric;
  v_pix_conta text;
  v_date_end date;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para criar locações';
  end if;

  if p_event_date_end is not null and p_event_date_end < p_event_date then
    raise exception 'A data final do período não pode ser antes da data inicial.';
  end if;
  v_date_end := coalesce(p_event_date_end, p_event_date);

  select code into v_equipment_code from equipments where id = p_equipment_id;
  select name, parceiro into v_client_name, v_parceiro from clients where id = p_client_id;
  select id into v_category_id from categories where type = 'entrada' and is_default = true and name ilike 'Loca%' limit 1;

  if v_category_id is null then
    raise exception 'Categoria "Locação" não encontrada (foi renomeada ou removida?). Ajuste o cadastro de categorias antes de criar a locação.';
  end if;

  insert into rentals (client_id, equipment_id, event_date, event_date_end, shots, calculated_value, payment_method, notes, created_by)
  values (p_client_id, p_equipment_id, p_event_date, p_event_date_end, p_shots, p_calculated_value, p_payment_method, p_notes, v_created_by)
  returning id into v_rental_id;

  if p_pago then
    v_pix_conta := case when p_payment_method = 'pix' then coalesce(p_pix_conta, 'harmonize') else null end;

    insert into transactions (type, category_id, description, amount, payment_method, date, scope, client_id, rental_id, created_by)
    values ('entrada', v_category_id, 'Locação HIPRO - ' || coalesce(v_client_name, ''), p_calculated_value, p_payment_method, p_event_date, 'harmonize', p_client_id, v_rental_id, v_created_by)
    returning id into v_transaction_id;

    insert into rental_payments (rental_id, forma, valor, data, pix_conta, transaction_id, created_by)
    values (v_rental_id, p_payment_method, p_calculated_value, p_event_date, v_pix_conta, v_transaction_id, v_created_by);

    update rentals set transaction_id = v_transaction_id where id = v_rental_id;
    -- pago / pago_em: preenchidos automaticamente pelo trigger de rental_payments.
  end if;

  -- Taxa de compromisso inicial: pendente só quando há data futura a
  -- garantir e o cliente não é parceiro. definir_taxa_agendamento muda o
  -- estado depois.
  if coalesce(v_parceiro, false) or p_event_date <= public.hoje_local() then
    v_taxa_status := 'nao_aplica';
    v_taxa_valor  := null;
  else
    v_taxa_status := 'pendente';
    v_taxa_valor  := public.valor_taxa_atual();
  end if;

  insert into calendar_events (event_type, title, client_id, equipment_id, date_start, date_end, status, value, rental_id, created_by, taxa_status, taxa_valor)
  values (v_equipment_code::text::calendar_event_type, 'Locação - ' || coalesce(v_client_name, ''), p_client_id, p_equipment_id, p_event_date, v_date_end, 'confirmada', p_calculated_value, v_rental_id, v_created_by,
          v_taxa_status, v_taxa_valor);

  update clients set stage = 'cliente' where id = p_client_id and stage <> 'cliente';

  return v_rental_id;
end;
$$;

grant execute on function public.create_rental(uuid, uuid, date, integer, numeric, payment_method_type, text, boolean, text, date) to authenticated;

-- update_rental ganha p_event_date_end (leva W), mesmo motivo/mesmo
-- padrão do bloco acima: apaga todas as versões existentes antes de
-- recriar, não só uma assinatura específica.
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'update_rental'
  loop
    execute format('drop function %s', r.sig);
  end loop;
end $$;

create or replace function public.update_rental(
  p_rental_id uuid,
  p_equipment_id uuid,
  p_event_date date,
  p_shots integer,
  p_calculated_value numeric,
  p_payment_method payment_method_type,
  p_status event_status_type,
  p_notes text default null,
  p_event_date_end date default null
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
  v_date_end date;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para editar locações';
  end if;

  if p_event_date_end is not null and p_event_date_end < p_event_date then
    raise exception 'A data final do período não pode ser antes da data inicial.';
  end if;
  v_date_end := coalesce(p_event_date_end, p_event_date);

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
      event_date_end = p_event_date_end,
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
      date_end = v_date_end,
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

grant execute on function public.update_rental(uuid, uuid, date, integer, numeric, payment_method_type, event_status_type, text, date) to authenticated;
