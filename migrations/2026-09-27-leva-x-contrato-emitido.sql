-- ============================================================
-- LEVA X: geração de contrato de locação em PDF (sob demanda, sem
-- guardar o arquivo) + controle dos contratos emitidos.
--
-- CONTEXTO: a Leva W já tinha adicionado clients.document (CPF/CNPJ) e
-- equipments.serial_number/anvisa_registro pensando exatamente nisso.
-- Faltava: (1) quem assina o contrato e recebe a nota fiscal pode ser
-- uma pessoa/empresa diferente da cadastrada como cliente (ex: a
-- clínica paga e emite a NF-e, mas o cliente cadastrado é a médica) —
-- por isso os campos abaixo, que servem de PADRÃO mas continuam
-- editáveis a cada geração; (2) como o PDF não fica salvo no sistema
-- (gerado sob demanda, direto no navegador), o "controle dos emitidos"
-- guarda um retrato (snapshot) completo de cada geração, pra dar pra
-- reabrir e gerar o mesmo PDF de novo depois mesmo que o cadastro do
-- cliente ou do equipamento mude no meio do caminho.
-- ============================================================

-- Nome/razão social e endereço alternativos para contrato e NF-e,
-- quando diferentes do cadastro do cliente (ex: cliente cadastrado é a
-- pessoa física da clínica, mas quem contrata/paga é a pessoa jurídica).
-- Nulos = usa clients.name / clients.address normalmente. clients.document
-- (leva W) já cumpre esse papel para o documento, só ganha aqui um
-- comentário atualizado deixando claro que também serve para a NF-e.
alter table public.clients add column if not exists contrato_nome text;
alter table public.clients add column if not exists contrato_endereco text;

comment on column public.clients.contrato_nome is
  'Nome/razão social a usar no contrato de locação e na NF-e quando for diferente do nome cadastrado (leva X). Nulo = usa clients.name. Editável também na hora de gerar cada contrato, sem alterar este padrão.';
comment on column public.clients.contrato_endereco is
  'Endereço a usar no contrato de locação e na NF-e quando for diferente do endereço cadastrado (leva X). Nulo = usa clients.address. Editável também na hora de gerar cada contrato, sem alterar este padrão.';
comment on column public.clients.document is
  'CPF ou CNPJ do contratante, texto livre sem validação rígida de formato (leva W). Usado como padrão na geração do contrato de locação e na NF-e (leva X) — editável a cada geração sem alterar o cadastro.';

-- ------------------------------------------------------------
-- CONTROLE DOS CONTRATOS EMITIDOS (leva X)
-- ------------------------------------------------------------
create table public.contratos_emitidos (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id),
  client_id uuid not null references public.clients(id),
  gerado_em timestamptz not null default now(),
  gerado_por uuid references public.profiles(id),
  -- Retrato completo dos dados usados nesta geração (contratante,
  -- equipamento, período, valor, forma de pagamento) — permite reabrir e
  -- gerar de novo o MESMO pdf depois, mesmo que o cadastro do cliente ou
  -- do equipamento tenha mudado nesse meio tempo. Formato livre (o
  -- componente de PDF é quem define o shape), não é validado aqui.
  dados jsonb not null,
  is_test boolean not null default false
);

comment on table public.contratos_emitidos is
  'Registro de cada contrato de locação gerado (leva X). O PDF em si não fica salvo no sistema — é gerado sob demanda, direto no navegador. "dados" guarda o retrato completo usado naquela geração, pra permitir baixar de novo o mesmo documento depois.';

create index contratos_emitidos_rental_id_idx on public.contratos_emitidos(rental_id);
create index contratos_emitidos_client_id_idx on public.contratos_emitidos(client_id);
create index contratos_emitidos_gerado_em_idx on public.contratos_emitidos(gerado_em desc);
create index contratos_emitidos_is_test_idx on public.contratos_emitidos(id) where is_test;

alter table public.contratos_emitidos enable row level security;

-- Mesmo padrão de movimentacoes: leitura por módulo (agenda, já que o
-- contrato nasce de uma locação), sem policy de insert/update/delete —
-- só a função abaixo (security definer) escreve aqui, pra o registro não
-- poder ser fabricado ou alterado por fora dela.
create policy "contratos_emitidos_select" on contratos_emitidos for select using (has_module_permission('agenda'));

grant select on public.contratos_emitidos to authenticated;

create trigger contratos_emitidos_apply_test_mode
  before insert on public.contratos_emitidos
  for each row execute function public.apply_test_mode();

create or replace function public.registrar_contrato_emitido(
  p_rental_id uuid,
  p_dados jsonb
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

  select client_id into v_client_id from rentals where id = p_rental_id;
  if v_client_id is null then
    raise exception 'Locação não encontrada (id %).', p_rental_id;
  end if;

  insert into contratos_emitidos (rental_id, client_id, gerado_por, dados)
  values (p_rental_id, v_client_id, auth.uid(), p_dados)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.registrar_contrato_emitido(uuid, jsonb) to authenticated;
