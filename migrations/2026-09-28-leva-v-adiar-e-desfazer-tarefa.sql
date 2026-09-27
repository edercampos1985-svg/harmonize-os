-- ============================================================
-- LEVA V: adiar e desfazer conclusão de tarefas
--
-- CONTEXTO
-- Pedido do usuário: dar um jeito de (1) adiar uma tarefa pendente pra
-- outra data, e (2) desfazer a conclusão de uma tarefa marcada como
-- feita por engano.
--
-- (1) Adiar é só trocar tasks.due_date — não tem regra de negócio
-- nenhuma por trás, então não precisa de função nova: a RLS de tasks já
-- permite update direto pra quem tem o módulo 'clientes' (mesmo caminho
-- que a tela já usa pra completeManualTask). A mudança fica só no
-- front-end (TarefasClient.tsx).
--
-- (2) Desfazer é a parte que precisa de cuidado. Tarefa manual não tem
-- efeito colateral nenhum ao concluir, mas tarefa de funil
-- (contato_inicial/followup) passa por register_contact_attempt, que:
--   - remove a tag "Follow-up N" do cliente;
--   - se "sem resposta", cria a PRÓXIMA tarefa de follow-up (ou move o
--     cliente pra 'nutricao' quando passa do follow-up 5).
-- Desfazer sem cuidar disso deixaria uma tarefa "fantasma" criada a
-- mais, ou o cliente com a tag errada. A função abaixo:
--   - só desfaz se a tarefa seguinte (se existir) ainda estiver
--     intocada (pendente) — se já foi mexida, bloqueia com uma
--     mensagem clara, pra não bagunçar o histórico do funil;
--   - remove a tarefa seguinte que tinha sido criada (ela deixa de
--     fazer sentido, já que a pergunta dela só existe por causa da
--     conclusão que está sendo desfeita);
--   - recoloca a tag "Follow-up N" que tinha sido removida.
-- Não tenta desfazer a mudança de estágio para 'nutricao' (quando
-- passou do follow-up 5) porque o estágio anterior não fica guardado
-- em lugar nenhum — nesse caso raro, avisa e quem usar ajusta o
-- estágio manualmente se precisar.
-- ============================================================

create or replace function public.desfazer_conclusao_tarefa(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_type text;
  v_follow_up_number integer;
  v_status text;
  v_next_task_id uuid;
  v_next_task_status text;
  v_tag_id uuid;
begin
  if not has_module_permission('clientes') then
    raise exception 'Sem permissão para alterar tarefas.';
  end if;

  select client_id, type, follow_up_number, status
    into v_client_id, v_type, v_follow_up_number, v_status
    from tasks where id = p_task_id;

  if not found then
    raise exception 'Tarefa não encontrada.';
  end if;

  if v_status <> 'concluida' then
    raise exception 'Esta tarefa não está concluída.';
  end if;

  if v_type in ('contato_inicial', 'followup') and v_client_id is not null then
    select id, status into v_next_task_id, v_next_task_status
      from tasks
     where client_id = v_client_id
       and type = 'followup'
       and follow_up_number = coalesce(v_follow_up_number, 0) + 1
     order by created_at desc
     limit 1;

    if v_next_task_id is not null then
      if v_next_task_status <> 'pendente' then
        raise exception 'Não dá para desfazer: já existe uma tarefa de follow-up seguinte que já foi mexida. Desfaça essa primeiro.';
      end if;
      delete from tasks where id = v_next_task_id;
    end if;

    if v_follow_up_number is not null then
      select id into v_tag_id from tags where name = 'Follow-up ' || v_follow_up_number;
      if v_tag_id is not null then
        insert into client_tags (client_id, tag_id) values (v_client_id, v_tag_id)
        on conflict do nothing;
      end if;
    end if;
  end if;

  update tasks set status = 'pendente', completed_at = null where id = p_task_id;

  perform public.registrar_movimentacao(
    'editado', 'tasks', p_task_id, public.descrever_registro('tasks', p_task_id),
    jsonb_build_object('acao_detalhada', 'Conclusão da tarefa desfeita (reaberta por engano)')
  );
end;
$$;

grant execute on function public.desfazer_conclusao_tarefa to authenticated;
