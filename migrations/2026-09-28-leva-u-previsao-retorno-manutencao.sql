-- ============================================================
-- LEVA U: previsão de retorno da manutenção, com aviso e retorno
-- automático
--
-- CONTEXTO
-- Depois da leva T (manutenção bloqueia agenda), o usuário pediu duas
-- coisas: (1) que o erro de bloqueio mostre o motivo de verdade em vez
-- de uma mensagem genérica — isso foi corrigido só no front-end (ver
-- ReservarHiproModal.tsx, EditarLocacaoModal.tsx e
-- CalculadoraLocacaoModal.tsx, que agora exibem insertError.message /
-- rpcError.message em vez de um texto fixo); e (2) marcar uma previsão
-- de quando o equipamento volta, com aviso 2 dias antes e retorno
-- automático quando a data chega.
--
-- IMPORTANTE — como o "automático" funciona aqui
-- Este projeto não tem nenhum job agendado rodando sozinho (sem
-- pg_cron, sem cron da Vercel). Em vez de criar essa infraestrutura
-- nova, o retorno automático é aplicado "sob demanda": toda vez que a
-- tela de Equipamentos é aberta, ou que alguém tenta reservar/trocar
-- equipamento na Agenda, o banco primeiro confere se alguma previsão
-- já venceu e devolve o equipamento para 'ativo' antes de continuar.
-- Na prática ninguém precisa clicar em nada — só não é cravado no
-- segundo exato da meia-noite, e sim "na próxima vez que alguém olhar
-- a tela ou tentar reservar".
--
-- O QUE MUDA
-- 1) equipments ganha status_previsto_fim (date, opcional).
-- 2) definir_status_equipamento ganha o parâmetro p_previsto_fim.
-- 3) Nova função aplicar_previsoes_manutencao_vencidas(): devolve para
--    'ativo' todo equipamento cuja previsão já passou.
-- 4) validar_equipamento_coerente passa a chamar essa função antes de
--    checar o status, e a tela de Equipamentos também chama antes de
--    montar a lista.
-- 5) Nova função adiar_previsao_manutencao(), para o botão "Adiar" do
--    aviso que aparece 2 dias antes da previsão.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Coluna nova
-- ------------------------------------------------------------
alter table public.equipments
  add column if not exists status_previsto_fim date;

comment on column public.equipments.status_previsto_fim is
  'Data prevista de retorno da manutenção (leva U). Opcional; null quando não informada ou quando ativo.';

-- ------------------------------------------------------------
-- 2. definir_status_equipamento ganha p_previsto_fim
-- ------------------------------------------------------------
create or replace function public.definir_status_equipamento(
  p_equipment_id uuid,
  p_status text,
  p_motivo text default null,
  p_previsto_fim date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
  v_status_atual text;
  v_detalhes jsonb;
begin
  if not has_module_permission('agenda') then
    raise exception 'Sem permissão para alterar o status de equipamentos.';
  end if;

  if p_status not in ('ativo', 'manutencao') then
    raise exception 'Status inválido: %. Use ''ativo'' ou ''manutencao''.', p_status;
  end if;

  if p_status = 'manutencao' and p_previsto_fim is not null and p_previsto_fim < current_date then
    raise exception 'A previsão de retorno não pode ser uma data no passado.';
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
         status_desde = now(),
         status_previsto_fim = case when p_status = 'manutencao' then p_previsto_fim else null end
   where id = p_equipment_id;

  v_detalhes := jsonb_build_object('motivo', coalesce(nullif(trim(p_motivo), ''), 'não informado'));
  if p_status = 'manutencao' and p_previsto_fim is not null then
    v_detalhes := v_detalhes || jsonb_build_object('previsto_fim', to_char(p_previsto_fim, 'DD/MM/YYYY'));
  end if;

  perform public.registrar_movimentacao(
    case p_status when 'manutencao' then 'manutencao_iniciada' else 'manutencao_finalizada' end,
    'equipments', p_equipment_id, 'Equipamento ' || v_nome,
    v_detalhes
  );
end;
$$;

grant execute on function public.definir_status_equipamento to authenticated;

-- ------------------------------------------------------------
-- 3. aplicar_previsoes_manutencao_vencidas — o "cron sob demanda"
-- ------------------------------------------------------------
create or replace function public.aplicar_previsoes_manutencao_vencidas()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_equip record;
begin
  for v_equip in
    select id, name from equipments
     where status = 'manutencao'
       and status_previsto_fim is not null
       and status_previsto_fim <= current_date
  loop
    update equipments
       set status = 'ativo',
           status_motivo = null,
           status_desde = now(),
           status_previsto_fim = null
     where id = v_equip.id;

    perform public.registrar_movimentacao(
      'manutencao_finalizada', 'equipments', v_equip.id, 'Equipamento ' || v_equip.name,
      jsonb_build_object('motivo', 'retorno automático: a previsão de volta foi atingida')
    );
  end loop;
end;
$$;

grant execute on function public.aplicar_previsoes_manutencao_vencidas to authenticated;

-- ------------------------------------------------------------
-- 4. validar_equipamento_coerente chama a função acima antes de olhar
--    o status, para a Agenda nunca recusar (ou aceitar) com base num
--    status que já venceu.
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
  perform public.aplicar_previsoes_manutencao_vencidas();

  if new.event_type in ('hipro_1', 'hipro_2') then
    if new.equipment_id is null then
      raise exception 'Evento do tipo % precisa de um equipamento vinculado.', new.event_type;
    end if;
    select code, status into v_equipment_code, v_equipment_status from equipments where id = new.equipment_id;
    if v_equipment_code::text is distinct from new.event_type::text then
      raise exception 'Evento do tipo % não pode apontar para o equipamento %.', new.event_type, v_equipment_code;
    end if;
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
-- 5. adiar_previsao_manutencao — botão "Adiar" do aviso de 2 dias antes
-- ------------------------------------------------------------
create or replace function public.adiar_previsao_manutencao(
  p_equipment_id uuid,
  p_nova_previsao date
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
    raise exception 'Sem permissão para alterar a previsão de manutenção.';
  end if;

  if p_nova_previsao < current_date then
    raise exception 'A nova previsão não pode ser uma data no passado.';
  end if;

  select name, status into v_nome, v_status_atual from equipments where id = p_equipment_id;
  if v_nome is null then
    raise exception 'Equipamento não encontrado (id %).', p_equipment_id;
  end if;
  if v_status_atual <> 'manutencao' then
    raise exception 'Este equipamento não está em manutenção no momento.';
  end if;

  update equipments set status_previsto_fim = p_nova_previsao where id = p_equipment_id;

  perform public.registrar_movimentacao(
    'editado', 'equipments', p_equipment_id, 'Equipamento ' || v_nome,
    jsonb_build_object('acao_detalhada', 'Previsão de retorno adiada para ' || to_char(p_nova_previsao, 'DD/MM/YYYY'))
  );
end;
$$;

grant execute on function public.adiar_previsao_manutencao to authenticated;
