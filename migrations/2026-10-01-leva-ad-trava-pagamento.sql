-- ============================================================
-- LEVA AD: registrar_pagamento_locacao deixa de aceitar pagamento
-- maior que o saldo em aberto (saldo já desconta taxa de reserva paga).
-- Assinatura inalterada: create or replace basta. Rodar também no SQL
-- editor do Supabase. Seguro rodar de novo.
-- ============================================================

create or replace function public.registrar_pagamento_locacao(
  p_rental_id uuid,
  p_forma payment_method_type,
  p_valor numeric,
  p_data date default public.hoje_local(),
  p_pix_conta text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_client_name text;
  v_status event_status_type;
  v_categoria uuid;
  v_transacao_id uuid;
  v_payment_id uuid;
  v_saldo numeric;
begin
  if not has_module_permission('financeiro') then
    raise exception 'Sem permissão para registrar pagamentos.';
  end if;
  if p_valor <= 0 then
    raise exception 'O valor do pagamento precisa ser maior que zero.';
  end if;
  if p_forma = 'pix' and p_pix_conta is null then
    raise exception 'Informe em qual conta o PIX caiu.';
  end if;

  select r.client_id, r.status, c.name into v_client_id, v_status, v_client_name
    from rentals r
    left join clients c on c.id = r.client_id
   where r.id = p_rental_id;

  if v_client_id is null then
    raise exception 'Locação não encontrada.';
  end if;
  if v_status = 'cancelada' then
    raise exception 'Esta locação está cancelada. Reative o agendamento antes de registrar o pagamento.';
  end if;

  -- Leva AD: não aceita pagamento acima do que falta receber. O saldo já
  -- desconta a taxa de reserva paga. Se o cliente realmente pagou a mais,
  -- corrija antes o valor da locação em "Editar locação".
  select saldo into v_saldo from rentals_situacao_pagamento where rental_id = p_rental_id;
  if round(p_valor, 2) > round(coalesce(v_saldo, 0), 2) then
    raise exception 'O pagamento (R$ %) é maior que o saldo em aberto (R$ %). Ajuste o valor da locação antes, se o cliente pagou a mais.',
      to_char(round(p_valor, 2), 'FM999G990D00'), to_char(round(coalesce(v_saldo, 0), 2), 'FM999G990D00');
  end if;

  select id into v_categoria
    from categories
   where type = 'entrada' and is_default = true and name ilike 'Loca%'
   limit 1;

  insert into transactions (
    type, category_id, description, amount, payment_method, date, scope,
    client_id, rental_id, notes, created_by
  )
  values (
    'entrada', v_categoria,
    'Locação HIPRO - ' || coalesce(v_client_name, ''),
    p_valor, p_forma, p_data, 'harmonize', v_client_id, p_rental_id, p_notes, auth.uid()
  )
  returning id into v_transacao_id;

  insert into rental_payments (rental_id, forma, valor, data, pix_conta, transaction_id, notes, created_by)
  values (p_rental_id, p_forma, p_valor, p_data, p_pix_conta, v_transacao_id, p_notes, auth.uid())
  returning id into v_payment_id;

  perform public.registrar_movimentacao(
    'pago', 'rentals', p_rental_id,
    public.descrever_registro('rentals', p_rental_id),
    jsonb_build_object('valor_pago', round(p_valor, 2), 'forma', p_forma::text, 'pix_conta', p_pix_conta)
  );

  return v_payment_id;
end;
$$;

comment on function public.registrar_pagamento_locacao(uuid, payment_method_type, numeric, date, text, text) is
  'Registra UM pagamento de uma locação (parcial ou não). Chamar de novo para dividir entre formas ou completar um saldo em aberto — rentals.pago/pago_em se ajustam sozinhos pelo trigger de rental_payments.';

grant execute on function public.registrar_pagamento_locacao to authenticated;
