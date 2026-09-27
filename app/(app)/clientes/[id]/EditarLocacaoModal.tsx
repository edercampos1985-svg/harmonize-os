"use client";

import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { calculateRentalValue, type PricingConfig } from "@/lib/rental-pricing";
import { formatCurrency } from "@/lib/format";
import ClientPicker, { type ClientOption } from "@/components/ClientPicker";

const PAYMENT_METHODS = [
  { value: "pix", label: "PIX" },
  { value: "dinheiro", label: "Dinheiro" },
  { value: "debito", label: "Débito" },
  { value: "credito", label: "Crédito" },
  { value: "transferencia", label: "Transferência" },
  { value: "outros", label: "Outros" },
];

// Leva S: "cancelada" saiu daqui de propósito — cancelar agora é uma
// ação dedicada (botão "Cancelar locação" mais abaixo), não mais um
// valor deste dropdown, para sempre passar pelas regras de negócio do
// cancelamento (taxa perdida, bloqueio se já paga, motivo/no-show).
const STATUS_OPTIONS = [
  { value: "pre_reserva", label: "Pré-reserva" },
  { value: "confirmada", label: "Confirmada" },
  { value: "realizada", label: "Realizada" },
];

interface EquipmentOption {
  id: string;
  code: string;
  name: string;
}

interface RentalToEdit {
  id: string;
  equipment_id: string;
  event_date: string;
  // Leva W: data final quando a locação cobre mais de um dia. Nulo/
  // ausente = locação de um dia só (o caso comum).
  event_date_end?: string | null;
  shots: number;
  calculated_value: number;
  payment_method: string;
  status: string;
  notes: string | null;
}

export default function EditarLocacaoModal({
  rental,
  equipments,
  pricingConfig,
  currentClientId,
  currentClientName,
  onClose,
  onSaved,
}: {
  rental: RentalToEdit;
  equipments: EquipmentOption[];
  pricingConfig?: PricingConfig;
  // Leva P.2: cliente atual desta locação (a página de onde o modal é
  // aberto é sempre a ficha de UM cliente, então não vem em `rental`).
  // Junto com a lista buscada abaixo, dá pra trocar o cliente quando a
  // locação foi lançada na pessoa errada.
  currentClientId: string;
  currentClientName: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const supabase = createClient();
  const [equipmentId, setEquipmentId] = useState(rental.equipment_id);
  const [eventDate, setEventDate] = useState(rental.event_date);
  // Leva W: período de vários dias. Nasce marcado se a locação já era um
  // período (edição de uma locação existente); senão nasce fechado, já
  // que é a exceção.
  const [isPeriodo, setIsPeriodo] = useState(!!rental.event_date_end);
  const [eventDateEnd, setEventDateEnd] = useState(rental.event_date_end ?? "");
  const [shots, setShots] = useState(String(rental.shots));
  const [valor, setValor] = useState(String(rental.calculated_value));
  const [paymentMethod, setPaymentMethod] = useState(rental.payment_method);
  const [status, setStatus] = useState(rental.status);
  const [notes, setNotes] = useState(rental.notes ?? "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Leva S: cancelar deixou de ser uma opção do dropdown de status —
  // passa por uma RPC dedicada (cancelar_locacao), que aplica as mesmas
  // regras de cancelar_agendamento (bloqueia se já foi paga, taxa paga
  // vira perdida, motivo e não-comparecimento ficam registrados).
  const [showCancelForm, setShowCancelForm] = useState(false);
  const [cancelMotivo, setCancelMotivo] = useState("");
  const [cancelNoShow, setCancelNoShow] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [cancelError, setCancelError] = useState<string | null>(null);

  async function handleCancelarLocacao() {
    setCancelling(true);
    setCancelError(null);
    const { error: rpcError } = await supabase.rpc("cancelar_locacao", {
      p_rental_id: rental.id,
      p_motivo: cancelMotivo || null,
      p_no_show: cancelNoShow,
    });
    setCancelling(false);
    if (rpcError) {
      setCancelError(rpcError.message || "Não foi possível cancelar. Tente novamente.");
      return;
    }
    onSaved();
  }

  // ------------------------------------------------------------
  // Cliente (leva P.2): corrige quando a locação foi lançada na pessoa
  // errada. Busca a lista de clientes só quando o modal abre (a página
  // de origem não carrega essa lista, já que normalmente é fixa em um
  // cliente só).
  // ------------------------------------------------------------
  const [clientId, setClientId] = useState(currentClientId);
  const [clientOptions, setClientOptions] = useState<ClientOption[]>([{ id: currentClientId, name: currentClientName }]);
  useEffect(() => {
    supabase
      .from("clients")
      .select("id, name")
      .order("name")
      .then(({ data }) => {
        if (data && data.length > 0) setClientOptions(data);
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const shotsNumber = Number(shots.replace(/\D/g, ""));

  const suggestedValue = useMemo(() => {
    if (!shotsNumber || shotsNumber <= 0) return null;
    try {
      return calculateRentalValue(shotsNumber, pricingConfig).totalValue;
    } catch {
      return null;
    }
  }, [shotsNumber, pricingConfig]);

  function usarValorSugerido() {
    if (suggestedValue !== null) setValor(String(suggestedValue));
  }

  async function handleSave() {
    const valorNumber = Number(valor.replace(",", "."));
    if (!clientId) {
      setError("Selecione o cliente.");
      return;
    }
    if (!equipmentId || !eventDate || !shotsNumber || !valorNumber) {
      setError("Preencha equipamento, data, disparos e valor.");
      return;
    }
    if (isPeriodo && (!eventDateEnd || eventDateEnd < eventDate)) {
      setError("Informe uma data final válida (igual ou depois da data inicial).");
      return;
    }
    if (!window.confirm("Salvar essas alterações na locação?")) return;
    setSaving(true);
    setError(null);

    // Cliente trocado primeiro (leva P.2): se falhar, não chega a mexer
    // no resto — evita salvar equipamento/data/valor novos numa locação
    // que ficou com o cliente errado por causa de um erro no meio.
    if (clientId !== currentClientId) {
      const { error: transferError } = await supabase.rpc("transferir_cliente_locacao", {
        p_rental_id: rental.id,
        p_novo_client_id: clientId,
      });
      if (transferError) {
        setSaving(false);
        setError("Não foi possível trocar o cliente desta locação. Tente novamente.");
        return;
      }
    }

    const { error: rpcError } = await supabase.rpc("update_rental", {
      p_rental_id: rental.id,
      p_equipment_id: equipmentId,
      p_event_date: eventDate,
      p_shots: shotsNumber,
      p_calculated_value: valorNumber,
      p_payment_method: paymentMethod,
      p_status: status,
      p_notes: notes || null,
      p_event_date_end: isPeriodo ? eventDateEnd : null,
    });

    setSaving(false);

    if (rpcError) {
      if (rpcError.code === "23P01") {
        setError("⚠️ Esse equipamento já está reservado nessa data.");
      } else {
        setError(rpcError.message || "Não foi possível salvar. Tente novamente.");
      }
      return;
    }
    onSaved();
  }

  return (
    <div className="fixed inset-0 z-20 flex items-end justify-center bg-black/40 sm:items-center" onClick={onClose}>
      <div
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-t-2xl bg-white/90 p-6 shadow-2xl backdrop-blur-2xl dark:bg-neutral-900/85 sm:rounded-3xl"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-lg font-semibold text-neutral-900 dark:text-neutral-100">Editar locação</h2>

        <div className="space-y-3">
          <div>
            <ClientPicker clients={clientOptions} value={clientId} onChange={setClientId} onClientCreated={(c) => setClientOptions((prev) => [...prev, c])} />
            {clientId !== currentClientId && (
              <p className="mt-1 text-xs text-amber-600">
                ⚠️ Isso muda o cliente desta locação — o financeiro e o evento na Agenda ligados a ela mudam junto.
              </p>
            )}
          </div>

          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Equipamento</label>
            <select
              value={equipmentId}
              onChange={(e) => setEquipmentId(e.target.value)}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            >
              {equipments.map((eq) => (
                <option key={eq.id} value={eq.id}>
                  {eq.name}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Data</label>
            <input
              type="date"
              value={eventDate}
              onChange={(e) => setEventDate(e.target.value)}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            />
          </div>

          <div>
            <label className="flex items-center gap-2 text-xs font-medium text-neutral-600 dark:text-neutral-400">
              <input
                type="checkbox"
                checked={isPeriodo}
                onChange={(e) => {
                  setIsPeriodo(e.target.checked);
                  if (!e.target.checked) setEventDateEnd("");
                }}
                className="h-4 w-4 rounded border-neutral-300 dark:border-neutral-700"
              />
              Locação de período (mais de um dia)
            </label>
            {isPeriodo && (
              <div className="mt-2">
                <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Até</label>
                <input
                  type="date"
                  value={eventDateEnd}
                  min={eventDate}
                  onChange={(e) => setEventDateEnd(e.target.value)}
                  className="w-full max-w-[200px] rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
                />
              </div>
            )}
          </div>

          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Disparos</label>
            <input
              inputMode="numeric"
              value={shots}
              onChange={(e) => setShots(e.target.value)}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            />
          </div>

          <div>
            <div className="mb-1 flex items-center justify-between">
              <label className="block text-xs font-medium text-neutral-600 dark:text-neutral-400">Valor final</label>
              {suggestedValue !== null && (
                <button
                  type="button"
                  onClick={usarValorSugerido}
                  className="text-xs text-brand-teal underline underline-offset-2"
                >
                  Usar sugerido: {formatCurrency(suggestedValue)}
                </button>
              )}
            </div>
            <input
              inputMode="decimal"
              value={valor}
              onChange={(e) => setValor(e.target.value)}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            />
            <p className="mt-1 text-xs text-neutral-400">
              Editável à parte, já que cobranças adicionais e descontos aplicados na criação não ficam guardados separadamente.
            </p>
          </div>

          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Forma de pagamento</label>
            <select
              value={paymentMethod}
              onChange={(e) => setPaymentMethod(e.target.value)}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            >
              {PAYMENT_METHODS.map((p) => (
                <option key={p.value} value={p.value}>
                  {p.label}
                </option>
              ))}
            </select>
          </div>

          {status === "cancelada" ? (
            <p className="rounded-lg border border-neutral-200 bg-neutral-50 px-3 py-2 text-xs text-neutral-500 dark:border-neutral-700 dark:bg-neutral-800/50 dark:text-neutral-400">
              Esta locação está cancelada. Para reativar, use "Reativar" na lista de agendamentos deste cliente.
            </p>
          ) : (
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Status</label>
              <select
                value={status}
                onChange={(e) => setStatus(e.target.value)}
                className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
              >
                {STATUS_OPTIONS.map((s) => (
                  <option key={s.value} value={s.value}>
                    {s.label}
                  </option>
                ))}
              </select>
            </div>
          )}

          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Observação</label>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            />
          </div>
        </div>

        {error && <p className="mt-3 text-sm text-red-600 dark:text-red-400">{error}</p>}

        <div className="mt-5 flex gap-2">
          <button
            onClick={onClose}
            className="flex-1 rounded-xl border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
          >
            Cancelar
          </button>
          <button
            onClick={handleSave}
            disabled={saving}
            className="flex-1 rounded-xl bg-brand-gradient py-2.5 text-sm font-medium text-white shadow-glow-teal transition hover:brightness-110 active:scale-[0.98] disabled:opacity-60 disabled:hover:brightness-100"
          >
            {saving ? "Salvando..." : "Salvar"}
          </button>
        </div>

        {status !== "cancelada" && (
          showCancelForm ? (
            <div className="mt-3 rounded-xl border border-red-200 p-3 dark:border-red-900/50">
              <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">
                Motivo do cancelamento (opcional)
              </label>
              <textarea
                value={cancelMotivo}
                onChange={(e) => setCancelMotivo(e.target.value)}
                rows={2}
                className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
              />
              <label className="mt-2 flex items-center gap-2 text-xs text-neutral-600 dark:text-neutral-400">
                <input
                  type="checkbox"
                  checked={cancelNoShow}
                  onChange={(e) => setCancelNoShow(e.target.checked)}
                />
                O cliente não compareceu (no-show)
              </label>
              {cancelError && <p className="mt-2 text-xs text-red-600 dark:text-red-400">{cancelError}</p>}
              <div className="mt-3 flex gap-2">
                <button
                  onClick={() => setShowCancelForm(false)}
                  className="flex-1 rounded-xl border border-neutral-300 py-2 text-xs font-medium text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
                >
                  Voltar
                </button>
                <button
                  onClick={handleCancelarLocacao}
                  disabled={cancelling}
                  className="flex-1 rounded-xl bg-red-600 py-2 text-xs font-medium text-white disabled:opacity-60"
                >
                  {cancelling ? "Cancelando..." : "Confirmar cancelamento"}
                </button>
              </div>
            </div>
          ) : (
            <button
              onClick={() => setShowCancelForm(true)}
              className="mt-3 w-full rounded-xl border border-red-200 py-2.5 text-sm font-medium text-red-600 dark:border-red-900/50 dark:text-red-400"
            >
              Cancelar locação
            </button>
          )
        )}
      </div>
    </div>
  );
}
