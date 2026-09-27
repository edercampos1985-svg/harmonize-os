-- ============================================================
-- LEVA S (correção): remove a sobra do cancelar_agendamento antigo
--
-- CONTEXTO
-- "create or replace function" não substitui uma função quando a lista
-- de parâmetros muda de tamanho — no Postgres isso conta como criar uma
-- função DISTINTA, com o mesmo nome. A migration da leva S criou
-- cancelar_agendamento(uuid, text, boolean) do lado da versão antiga
-- cancelar_agendamento(uuid, text), que continuou existindo. Com duas
-- funções de mesmo nome, o "grant execute on function
-- public.cancelar_agendamento" (sem especificar os parâmetros) ficou
-- ambíguo e falhou — foi o erro "function name ... is not unique" que
-- apareceu ao rodar a migration.
--
-- Como o editor de SQL do Supabase não desfaz o que já rodou quando um
-- comando falha no meio (confirmado na leva Q), a função nova (3
-- parâmetros) já foi criada, só não recebeu a permissão de execução —
-- por isso este ajuste sozinho resolve, sem precisar rodar a leva S
-- inteira de novo.
-- ============================================================

-- Remove a versão antiga (2 parâmetros): ela fica substituída pela de
-- 3 parâmetros (o terceiro, p_no_show, tem default, então continua
-- chamável passando só os 2 primeiros).
drop function if exists public.cancelar_agendamento(uuid, text);

-- Concede a permissão que tinha falhado, agora apontando exatamente
-- para a função de 3 parâmetros (sem ambiguidade, já que a antiga não
-- existe mais).
grant execute on function public.cancelar_agendamento(uuid, text, boolean) to authenticated;
