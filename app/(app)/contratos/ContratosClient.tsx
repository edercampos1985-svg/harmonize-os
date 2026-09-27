"use client";

import { useState } from "react";
import Link from "next/link";
import { formatCurrency, formatDate } from "@/lib/format";
import type { ContratoDados } from "@/lib/contrato-pdf";

interface ContratoRow {
  id: string;
  gerado_em: string;
  dados: ContratoDados;
  client_id: string;
  rental_id: string;
  clients?: { name: string } | null;
}

function formatPeriodo(dados: ContratoDados): string {
  const { event_date, event_date_end } = dados.locacao;
  if (event_date_end && event_date_end !== event_date) {
    return `${formatDate(event_date)} a ${formatDate(event_date_end)}`;
  }
  return formatDate(event_date);
}

export default function ContratosClient({
  contratos,
  atingiuTeto,
}: {
  contratos: ContratoRow[];
  atingiuTeto: boolean;
}) {
  const [busca, setBusca] = useState("");
  const [baixandoId, setBaixandoId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const termo = busca.trim().toLowerCase();
  const linhas = termo
    ? contratos.filter((c) => (c.clients?.name ?? c.dados.contratante.nome ?? "").toLowerCase().includes(termo))
    : contratos;

  async function handleBaixarNovamente(contrato: ContratoRow) {
    setError(null);
    setBaixandoId(contrato.id);
    try {
      // Import dinâmico: só carrega a biblioteca de PDF (pesada) quando
      // alguém de fato clica em "Baixar de novo".
      const { gerarContratoPdfBlob, baixarPdfBlob, nomeArquivoContrato } = await import("@/lib/contrato-pdf");
      const blob = await gerarContratoPdfBlob(contrato.dados);
      baixarPdfBlob(blob, nomeArquivoContrato(contrato.dados));
    } catch {
      setError("Não foi possível gerar o PDF agora. Tente novamente.");
    } finally {
      setBaixandoId(null);
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <h1 className="text-xl font-semibold text-neutral-900 dark:text-neutral-100">Contratos</h1>
        <input
          value={busca}
          onChange={(e) => setBusca(e.target.value)}
          placeholder="Buscar por cliente..."
          className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100 sm:w-64"
        />
      </div>

      <p className="text-xs text-neutral-400">
        O PDF não fica salvo no sistema — cada linha abaixo é um registro de que um contrato foi gerado, com os dados
        exatos usados, para poder baixar de novo quando precisar.
      </p>

      {error && <p className="text-sm text-red-600 dark:text-red-400">{error}</p>}

      {/* Celular: cartões empilhados */}
      <div className="space-y-2 sm:hidden">
        {linhas.map((c) => (
          <div
            key={c.id}
            className="rounded-xl border border-white/60 bg-white/70 p-3 shadow-sm backdrop-blur-xl dark:border-neutral-800/60 dark:bg-neutral-900/55"
          >
            <div className="flex items-start justify-between">
              <div>
                <Link href={`/clientes/${c.client_id}`} className="text-sm font-medium text-brand-teal underline underline-offset-2">
                  {c.clients?.name ?? c.dados.contratante.nome}
                </Link>
                <p className="mt-0.5 text-xs text-neutral-500 dark:text-neutral-400">{formatPeriodo(c.dados)}</p>
              </div>
              <span className="text-xs text-neutral-400">{formatDate(c.gerado_em.slice(0, 10))}</span>
            </div>
            <div className="mt-2 flex items-center justify-between">
              <span className="font-medium text-brand-teal">{formatCurrency(Number(c.dados.locacao.calculated_value))}</span>
              <button
                onClick={() => handleBaixarNovamente(c)}
                disabled={baixandoId === c.id}
                className="rounded-lg bg-brand-teal/10 px-3 py-1.5 text-xs font-medium text-brand-teal disabled:opacity-60"
              >
                {baixandoId === c.id ? "Gerando..." : "Baixar de novo"}
              </button>
            </div>
          </div>
        ))}
        {linhas.length === 0 && (
          <div className="rounded-xl border border-dashed border-neutral-300/70 bg-white/50 py-8 text-center text-neutral-400 backdrop-blur-xl dark:border-neutral-700/60 dark:bg-neutral-900/40">
            Nenhum contrato gerado ainda.
          </div>
        )}
      </div>

      {/* Tablet e notebook: tabela completa */}
      <div className="hidden overflow-x-auto rounded-2xl border border-white/60 bg-white/70 shadow-sm backdrop-blur-xl dark:border-neutral-800/60 dark:bg-neutral-900/55 sm:block">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-neutral-200 text-xs uppercase text-neutral-500 dark:border-neutral-800 dark:text-neutral-400">
            <tr>
              <th className="px-4 py-3">Gerado em</th>
              <th className="px-4 py-3">Cliente</th>
              <th className="px-4 py-3">Período</th>
              <th className="px-4 py-3 text-right">Valor</th>
              <th className="px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            {linhas.map((c) => (
              <tr key={c.id} className="border-b border-neutral-100 last:border-0 dark:border-neutral-800">
                <td className="whitespace-nowrap px-4 py-3 text-neutral-600 dark:text-neutral-400">
                  {formatDate(c.gerado_em.slice(0, 10))}
                </td>
                <td className="px-4 py-3">
                  <Link href={`/clientes/${c.client_id}`} className="text-brand-teal underline underline-offset-2">
                    {c.clients?.name ?? c.dados.contratante.nome}
                  </Link>
                </td>
                <td className="whitespace-nowrap px-4 py-3 text-neutral-600 dark:text-neutral-400">{formatPeriodo(c.dados)}</td>
                <td className="whitespace-nowrap px-4 py-3 text-right font-medium text-brand-teal">
                  {formatCurrency(Number(c.dados.locacao.calculated_value))}
                </td>
                <td className="whitespace-nowrap px-4 py-3 text-right">
                  <button
                    onClick={() => handleBaixarNovamente(c)}
                    disabled={baixandoId === c.id}
                    className="rounded-lg bg-brand-teal/10 px-3 py-1.5 text-xs font-medium text-brand-teal disabled:opacity-60"
                  >
                    {baixandoId === c.id ? "Gerando..." : "Baixar de novo"}
                  </button>
                </td>
              </tr>
            ))}
            {linhas.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-8 text-center text-neutral-400">
                  Nenhum contrato gerado ainda.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {atingiuTeto && (
        <p className="text-center text-xs text-neutral-400">Mostrando os {contratos.length} mais recentes.</p>
      )}
    </div>
  );
}
