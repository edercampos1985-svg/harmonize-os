"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { formatarDataHora } from "@/lib/movimentacoes";

// Leva T (E3): equipments.status existia desde sempre mas não tinha
// nenhuma tela para mudar de valor, então "manutenção" nunca bloqueava
// nada de verdade. Este controle é o que fecha essa ponta — troca o
// status pela RPC definir_status_equipamento (que já cuida de registrar
// em movimentacoes) e atualiza a página.
export default function EquipamentoStatusControl({
  equipmentId,
  status,
  statusMotivo,
  statusDesde,
}: {
  equipmentId: string;
  status: string;
  statusMotivo: string | null;
  statusDesde: string | null;
}) {
  const supabase = createClient();
  const router = useRouter();
  const [showForm, setShowForm] = useState(false);
  const [motivo, setMotivo] = useState("");
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const emManutencao = status === "manutencao";

  async function definirStatus(novoStatus: "ativo" | "manutencao", motivoParaEnviar: string | null) {
    setWorking(true);
    setError(null);
    const { error: rpcError } = await supabase.rpc("definir_status_equipamento", {
      p_equipment_id: equipmentId,
      p_status: novoStatus,
      p_motivo: motivoParaEnviar,
    });
    setWorking(false);
    if (rpcError) {
      setError(rpcError.message || "Não foi possível salvar. Tente novamente.");
      return;
    }
    setShowForm(false);
    setMotivo("");
    router.refresh();
  }

  return (
    <div>
      <p
        className={`mt-0.5 text-sm font-medium capitalize ${
          emManutencao ? "text-amber-600 dark:text-amber-400" : "text-neutral-900 dark:text-neutral-100"
        }`}
      >
        {emManutencao ? "Em manutenção" : "Ativo"}
      </p>
      {emManutencao && statusMotivo && (
        <p className="mt-0.5 text-[11px] text-neutral-500 dark:text-neutral-400">Motivo: {statusMotivo}</p>
      )}
      {emManutencao && statusDesde && (
        <p className="text-[11px] text-neutral-400">Desde {formatarDataHora(statusDesde)}</p>
      )}

      {error && <p className="mt-1 text-[11px] text-red-600 dark:text-red-400">{error}</p>}

      {emManutencao ? (
        <button
          type="button"
          disabled={working}
          onClick={() => definirStatus("ativo", null)}
          className="mt-2 rounded-lg border border-brand-teal px-3 py-1.5 text-xs font-medium text-brand-teal disabled:opacity-60"
        >
          {working ? "Salvando..." : "Voltar para ativo"}
        </button>
      ) : showForm ? (
        <div className="mt-2 rounded-lg bg-neutral-50 p-2 dark:bg-neutral-800/50">
          <label className="mb-1 block text-[11px] font-medium text-neutral-600 dark:text-neutral-400">
            Motivo (opcional)
          </label>
          <textarea
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
            rows={2}
            className="w-full rounded-lg border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
          />
          <div className="mt-2 flex gap-2">
            <button
              type="button"
              onClick={() => {
                setShowForm(false);
                setMotivo("");
                setError(null);
              }}
              className="flex-1 rounded-lg border border-neutral-300 py-1.5 text-xs font-medium text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
            >
              Desistir
            </button>
            <button
              type="button"
              disabled={working}
              onClick={() => definirStatus("manutencao", motivo)}
              className="flex-1 rounded-lg bg-amber-600 py-1.5 text-xs font-medium text-white disabled:opacity-60"
            >
              {working ? "Salvando..." : "Confirmar"}
            </button>
          </div>
        </div>
      ) : (
        <button
          type="button"
          onClick={() => setShowForm(true)}
          className="mt-2 rounded-lg border border-amber-300 px-3 py-1.5 text-xs font-medium text-amber-700 dark:border-amber-900/50 dark:text-amber-400"
        >
          Marcar em manutenção
        </button>
      )}
    </div>
  );
}
