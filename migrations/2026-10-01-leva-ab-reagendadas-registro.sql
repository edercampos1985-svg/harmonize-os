-- ============================================================
-- LEVA AB: registrar no repositório a marca de "reagendado" que já
-- existe no banco, e fechar o que faltava nela
--
-- CONTEXTO: as colunas calendar_events.rescheduled/rescheduled_at e
-- rentals.rescheduled_at, e a versão de reagendar_agendamento que grava
-- nelas, foram criadas direto no banco, sem migração. Esta leva só
-- traz isso para o repositório (tudo aqui é seguro de rodar de novo) e
-- corrige três pontos:
--
-- (1) reagendar_agendamento tinha perdido o `set search_path = public`,
--     proteção padrão de função security definer;
-- (2) reagendar pela tela "Editar locação" (update_rental) marcava
--     rentals.rescheduled mas não gravava QUANDO — um gatilho passa a
--     gravar rescheduled_at sempre que a data de uma locação muda, por
--     qualquer caminho, sem precisar reescrever update_rental;
-- (3) locações já marcadas como reagendadas antes de a coluna existir
--     ficaram sem data da ação — preenchidas a partir do histórico de
--     movimentações, onde todo reagendamento já era registrado.
-- ============================================================

alter table public.calendar_events add column if not exists rescheduled boolean not null default false;
alter table public.calendar_events add column if not exists rescheduled_at timestamptz;
alter table public.rentals add column if not exists rescheduled_at timestamptz;

comment on column public.calendar_events.rescheduled is
  'true = este agendamento já teve a data trocada alguma vez. Vale também para pré-reserva sem locação (leva AB); gravado por reagendar_agendamento.';
comment on column public.calendar_events.rescheduled_at is
  'Quando aconteceu o último reagendamento deste agendamento (a ação, não a nova data).';
comment on column public.rentals.rescheduled_at is
  'Quando aconteceu o último reagendamento desta locação (a ação, não a nova data). Gravado por reagendar_agendamento e, para qualquer outro caminho que mude event_date, pelo gatilho rentals_marca_reagendamento.';

create or replace function public.reagendar_agendamento(
  p_event_id uuid,
  p_nova_data date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data_antiga date;
  v_equipment_id uuid;
  v_rental_id uuid;
  v_status event_status_type;
  v_ocupante text;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para reagendar.';
  end if;

  select date_start, equipment_id, rental_id, status
    into v_data_antiga, v_equipment_id, v_rental_id, v_status
    from calendar_events where id = p_event_id;

  if v_data_antiga is null then
    raise exception 'Agendamento não encontrado.';
  end if;
  if v_status = 'cancelada' then
    raise exception 'Este agendamento está cancelado e não pode ser reagendado.';
  end if;
  if p_nova_data = v_data_antiga then
    raise exception 'A data nova é igual à atual.';
  end if;

  if v_equipment_id is not null then
    select coalesce(c.name, ev.title) into v_ocupante
      from calendar_events ev
      left join clients c on c.id = ev.client_id
     where ev.equipment_id = v_equipment_id
       and ev.status <> 'cancelada'
       and ev.id <> p_event_id
       and daterange(ev.date_start, ev.date_end, '[]') && daterange(p_nova_data, p_nova_data, '[]')
     limit 1;

    if v_ocupante is not null then
      raise exception 'O equipamento já está reservado em % para %.',
        to_char(p_nova_data, 'DD/MM/YYYY'), v_ocupante;
    end if;
  end if;

  -- A marca de reagendado vive em calendar_events, independente de já
  -- existir locação ou não (pré-reserva reagendada também conta).
  -- rescheduled_at registra QUANDO a ação aconteceu, que é o que o
  -- Dashboard usa para contar "reagendado no período".
  update calendar_events
     set date_start = p_nova_data,
         date_end   = p_nova_data,
         rescheduled = true,
         rescheduled_at = now()
   where id = p_event_id;

  if v_rental_id is not null then
    update rentals
       set event_date = p_nova_data,
           rescheduled = true,
           rescheduled_at = now()
     where id = v_rental_id;

    update transactions
       set date = p_nova_data
     where rental_id = v_rental_id;
  end if;

  perform public.registrar_movimentacao(
    'reagendado', 'calendar_events', p_event_id,
    public.descrever_registro('calendar_events', p_event_id),
    jsonb_build_object(
      'data_antiga', to_char(v_data_antiga, 'DD/MM/YYYY'),
      'data_nova',   to_char(p_nova_data, 'DD/MM/YYYY')
    )
  );

exception
  when exclusion_violation then
    raise exception 'O equipamento já está reservado em %.', to_char(p_nova_data, 'DD/MM/YYYY');
end;
$$;

grant execute on function public.reagendar_agendamento to authenticated;

-- Qualquer caminho que mude a data de uma locação (hoje: update_rental,
-- pela tela "Editar locação") passa a deixar gravado quando isso
-- aconteceu. Se quem fez a mudança já gravou rescheduled_at na mesma
-- operação (reagendar_agendamento), o gatilho não mexe.
create or replace function public.trg_rentals_marca_reagendamento()
returns trigger
language plpgsql
as $$
begin
  if new.event_date is distinct from old.event_date
     and new.rescheduled_at is not distinct from old.rescheduled_at then
    new.rescheduled := true;
    new.rescheduled_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_marca_reagendamento on public.rentals;
create trigger rentals_marca_reagendamento
  before update of event_date on public.rentals
  for each row execute function public.trg_rentals_marca_reagendamento();

-- Locações reagendadas antes de rescheduled_at existir: a data da ação
-- sai do histórico de movimentações (registrado na própria locação,
-- quando foi pela "Editar locação", ou no agendamento ligado a ela,
-- quando foi pelo botão "Reagendar").
update public.rentals r
   set rescheduled_at = h.quando
  from (
    select r2.id as rental_id, max(m.ocorrido_em) as quando
      from public.rentals r2
      join public.movimentacoes m
        on m.acao = 'reagendado'
       and (
         (m.entidade = 'rentals' and m.entidade_id = r2.id)
         or (m.entidade = 'calendar_events' and m.entidade_id in (
               select ev.id from public.calendar_events ev where ev.rental_id = r2.id))
       )
     group by r2.id
  ) h
 where h.rental_id = r.id
   and r.rescheduled = true
   and r.rescheduled_at is null;
