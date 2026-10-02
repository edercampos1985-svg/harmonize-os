-- ============================================================
-- LEVA AC: ajuda de custo (deslocamento) vira lançamento no financeiro
--
-- REGRA: entra no financeiro (Dashboard Entradas/Resultado/Saldo, tela
-- Financeiro) como entrada na categoria "Deslocamento", mas NÃO entra no
-- faturamento (que soma rentals.calculated_value). Forma de pagamento e
-- data são as da própria locação.
--
-- ANTI DUPLA CONTAGEM: quando o deslocamento foi calculado pela
-- calculadora (km -> valor), ele já está dentro de calculated_value e os
-- pagamentos da locação já cobrem o total. Nesse caso NÃO se cria
-- lançamento (rentals.deslocamento_incluso_no_valor = true).
--
-- Rodar também no SQL editor do Supabase. Seguro rodar de novo.
-- ============================================================

alter table public.rentals
  add column if not exists deslocamento_transaction_id uuid references public.transactions(id) on delete set null,
  add column if not exists deslocamento_incluso_no_valor boolean not null default false;

comment on column public.rentals.deslocamento_transaction_id is
  'Lançamento de entrada (categoria Deslocamento) que representa a ajuda de custo recebida. Nulo quando não há ajuda de custo lançada à parte.';
comment on column public.rentals.deslocamento_incluso_no_valor is
  'true = o deslocamento já está somado em calculated_value (veio da calculadora); nunca gerar lançamento próprio, senão conta duas vezes.';

-- Histórico: toda locação que já tinha deslocamento é tratada como "já somado
-- no valor", para nunca gerar lançamento automático em cima de dado antigo
-- (risco de contar duas vezes). Quem quiser lançar a ajuda de custo de uma
-- locação antiga desmarca "já está somado no valor" na tela de edição.
update public.rentals
   set deslocamento_incluso_no_valor = true
 where coalesce(valor_deslocamento, 0) > 0
   and deslocamento_transaction_id is null
   and deslocamento_incluso_no_valor = false;

-- Assinatura muda (novo parâmetro): remove todas as versões antes de recriar.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'definir_deslocamento_locacao'
  loop
    execute 'drop function ' || r.sig;
  end loop;
end $$;

create or replace function public.definir_deslocamento_locacao(
  p_rental_id uuid,
  p_km_ida numeric,
  p_valor_deslocamento numeric,
  p_incluso_no_valor boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_valor numeric := round(coalesce(p_valor_deslocamento, 0), 2);
  v_incluso boolean;
  v_tx_id uuid;
  v_client_id uuid;
  v_client_name text;
  v_forma payment_method_type;
  v_data date;
  v_categoria uuid;
  v_lancamento text := 'nenhum';
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para alterar locações.';
  end if;
  if p_valor_deslocamento is not null and p_valor_deslocamento < 0 then
    raise exception 'O valor de deslocamento não pode ser negativo.';
  end if;

  select deslocamento_incluso_no_valor, deslocamento_transaction_id, client_id, payment_method, event_date
    into v_incluso, v_tx_id, v_client_id, v_forma, v_data
    from rentals where id = p_rental_id;

  if not found then
    raise exception 'Locação não encontrada.';
  end if;

  if p_incluso_no_valor is not null then
    v_incluso := p_incluso_no_valor;
  end if;

  update rentals
     set km_ida = p_km_ida,
         valor_deslocamento = v_valor,
         deslocamento_incluso_no_valor = v_incluso
   where id = p_rental_id;

  if v_incluso or v_valor = 0 then
    -- Já está no valor da locação (ou foi zerado): não pode existir
    -- lançamento próprio.
    if v_tx_id is not null then
      if not has_module_permission('financeiro') then
        raise exception 'Sem permissão para alterar o lançamento financeiro da ajuda de custo.';
      end if;
      update rentals set deslocamento_transaction_id = null where id = p_rental_id;
      delete from transactions where id = v_tx_id;
      v_lancamento := 'removido';
    end if;
  else
    if not has_module_permission('financeiro') then
      raise exception 'Sem permissão para lançar a ajuda de custo no financeiro.';
    end if;

    if v_tx_id is not null then
      update transactions set amount = v_valor where id = v_tx_id;
      v_lancamento := 'atualizado';
    else
      select id into v_categoria
        from categories
       where type = 'entrada' and is_default = true and name ilike 'Deslocamento%'
       limit 1;
      select name into v_client_name from clients where id = v_client_id;

      insert into transactions (
        type, category_id, description, amount, payment_method, date, scope,
        client_id, rental_id, created_by
      )
      values (
        'entrada', v_categoria,
        'Ajuda de custo (deslocamento) - ' || coalesce(v_client_name, ''),
        v_valor, v_forma, v_data, 'harmonize', v_client_id, p_rental_id, auth.uid()
      )
      returning id into v_tx_id;

      update rentals set deslocamento_transaction_id = v_tx_id where id = p_rental_id;
      v_lancamento := 'criado';
    end if;
  end if;

  perform public.registrar_movimentacao(
    'editado', 'rentals', p_rental_id,
    public.descrever_registro('rentals', p_rental_id),
    jsonb_build_object(
      'acao_detalhada', 'deslocamento definido',
      'km_ida', p_km_ida,
      'valor_deslocamento', v_valor,
      'incluso_no_valor', v_incluso,
      'lancamento_financeiro', v_lancamento
    )
  );
end;
$$;

grant execute on function public.definir_deslocamento_locacao to authenticated;

-- Pré-reserva com ajuda de custo: ao finalizar, vira lançamento no financeiro.
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
  v_desloc_tx uuid;
  v_cat_desloc uuid;
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

  -- Leva AC: ajuda de custo registrada na pré-reserva vira entrada no
  -- financeiro ao finalizar (categoria Deslocamento, mesma forma de
  -- pagamento e data da locação). Se a calculadora depois incluir o
  -- deslocamento no valor, definir_deslocamento_locacao(p_incluso_no_valor
  -- => true) remove este lançamento para não contar duas vezes.
  if coalesce(v_valor_deslocamento, 0) > 0 then
    select id into v_cat_desloc from categories
     where type = 'entrada' and is_default = true and name ilike 'Deslocamento%' limit 1;

    insert into transactions (type, category_id, description, amount, payment_method, date, scope, client_id, rental_id, created_by)
    values (
      'entrada', v_cat_desloc,
      'Ajuda de custo (deslocamento) - ' || coalesce(v_client_name, ''),
      v_valor_deslocamento, p_payment_method, v_event_date, 'harmonize', v_client_id, v_rental_id, v_created_by
    )
    returning id into v_desloc_tx;

    update rentals set deslocamento_transaction_id = v_desloc_tx where id = v_rental_id;
  end if;

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

-- rentals_contabilizaveis usa select r.*: recriar para as colunas novas aparecerem.
create or replace view public.rentals_contabilizaveis
with (security_invoker = true) as
select r.*
from public.rentals r
where r.status <> 'cancelada'
  and r.is_test = false
  and not exists (
    select 1 from public.clients c
    where c.id = r.client_id and c.excluir_financeiro
  );
