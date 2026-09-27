-- ============================================================
-- LEVA Y: contrato assinado ANTES da locação, nunca depois
--
-- CONTEXTO: a leva X amarrou o "Gerar contrato" a uma linha de
-- `rentals` — mas essa linha só existe DEPOIS que a locação é lançada
-- ou finalizada, com disparos já contados. O usuário apontou a
-- contradição: o contrato tem que poder ser assinado já na pré-reserva
-- ("Agendar sem disparos", calendar_events com status pre_reserva),
-- antes de qualquer disparo existir, porque "o contrato sempre será
-- assinado antes da locação, nunca depois".
--
-- Esta leva: (1) contratos_emitidos.rental_id vira opcional e ganha um
-- par, reservation_id (calendar_events), com um check garantindo que
-- cada linha nasce de exatamente um dos dois; (2) registrar_contrato_
-- emitido passa a aceitar registrar por locação OU por pré-reserva. O
-- ajuste de texto do contrato (cláusula de valor nunca no passado) fica
-- só no componente de PDF (lib/contrato-pdf.tsx), sem mudança de banco.
-- ============================================================

alter table public.contratos_emitidos alter column rental_id drop not null;

alter table public.contratos_emitidos add column if not exists reservation_id uuid references public.calendar_events(id);

create index if not exists contratos_emitidos_reservation_id_idx on public.contratos_emitidos(reservation_id);

alter table public.contratos_emitidos drop constraint if exists contratos_emitidos_origem_check;
alter table public.contratos_emitidos add constraint contratos_emitidos_origem_check
  check (
    (rental_id is not null and reservation_id is null)
    or (rental_id is null and reservation_id is not null)
  );

comment on column public.contratos_emitidos.rental_id is
  'Preenchido quando o contrato nasce de uma locação já lançada (disparos/valor já combinados, mesmo que para data futura). Mutuamente exclusivo com reservation_id (leva Y).';
comment on column public.contratos_emitidos.reservation_id is
  'Preenchido quando o contrato nasce de uma pré-reserva ainda sem disparos contados (calendar_events, status pre_reserva) — o caso normal, já que o contrato é sempre assinado antes do procedimento (leva Y). Mutuamente exclusivo com rental_id.';

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'registrar_contrato_emitido'
  loop
    execute format('drop function %s', r.sig);
  end loop;
end $$;

create or replace function public.registrar_contrato_emitido(
  p_dados jsonb,
  p_rental_id uuid default null,
  p_reservation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_id uuid;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para gerar contratos.';
  end if;

  if p_rental_id is not null then
    select client_id into v_client_id from rentals where id = p_rental_id;
    if v_client_id is null then
      raise exception 'Locação não encontrada (id %).', p_rental_id;
    end if;
  elsif p_reservation_id is not null then
    select client_id into v_client_id from calendar_events where id = p_reservation_id;
    if v_client_id is null then
      raise exception 'Agendamento não encontrado (id %).', p_reservation_id;
    end if;
  else
    raise exception 'Informe a locação ou a pré-reserva de origem do contrato.';
  end if;

  insert into contratos_emitidos (rental_id, reservation_id, client_id, gerado_por, dados)
  values (p_rental_id, p_reservation_id, v_client_id, auth.uid(), p_dados)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.registrar_contrato_emitido(jsonb, uuid, uuid) to authenticated;
