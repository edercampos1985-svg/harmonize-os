"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { FileText } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import ConfirmarExclusaoModal from "@/components/ConfirmarExclusaoModal";
import CalculadoraLocacaoModal from "@/components/CalculadoraLocacaoModal";
import ClientPicker, { type ClientOption } from "@/components/ClientPicker";
import GerarContratoModal, { type OrigemContrato } from "@/components/GerarContratoModal";
import { calcularValorDeslocamento } from "@/lib/rental-calculator";
import { formatCurrency, formatDate } from "@/lib/format";
import type { PricingConfig, MentoriaPricingConfig } from "@/lib/rental-pricing";

const EQUIPMENT_LABELS: Record<string, string> = {
  hipro_1: "HIPRO 1",
  hipro_2: "HIPRO 2",
};

interface EventToEdit {
  id: string;
  event_type: string;
  title: string;
  date_start: string;
  status?: string;
  client_id: string | null;
  equipment_id?: string | null;
  rental_id: string | null;
  notes?: string | null;
  clients?: { name: string; whatsapp?: string | null } | null;
  // Estado atual da taxa deste agendamento (nao_aplica/pendente/paga/
  // perdida), repassado direto para a CalculadoraLocacaoModal (mode
  // "finalize") decidir o que oferecer.
  taxa_status?: string | null;
  // Reserva de HIPRO 1/2 marcada como mentoria (leva K) — muda o texto
  // desta tela e faz a CalculadoraLocacaoModal cobrar por paciente modelo
  // em vez de por disparo (leva M/N).
  is_mentoria?: boolean;
}

// Dados mínimos de equipamento e cliente para o contrato, buscados sob
// demanda aqui (a Agenda não carrega esses campos na lista principal,
// que só precisa do nome do equipamento e do cliente para os cards).
interface EquipamentoContratoInfo {
  name: string;
  serial_number?: string | null;
  anvisa_registro?: string | null;
}

interface ClienteContratoInfo {
  id: string;
  name: string;
  email?: string | null;
  document?: string | null;
  address?: string | null;
  display_name?: string | null;
  contrato_nome?: string | null;
  contrato_endereco?: string | null;
}

// Dados completos da locação (leva Z), buscados sob demanda quando o
// evento vem de uma locação já lançada: a Agenda só carrega rental_id,
// não o resto — precisa disso tanto para "Gerar contrato" quanto para o
// campo de deslocamento.
interface RentalDetails {
  id: string;
  event_date: string;
  event_date_end: string | null;
  shots: number;
  calculated_value: number;
  payment_method: string;
  equipment_id: string;
  km_ida: number | null;
  valor_deslocamento: number;
  equipments: EquipamentoContratoInfo | null;
}

export default function EditarEventoModal({
  event,
  clients,
  pricingConfig,
  reservationFee,
  mentoriaPricing,
  onClose,
  onSaved,
  onDeleted,
}: {
  event: EventToEdit;
  clients: ClientOption[];
  pricingConfig?: PricingConfig;
  reservationFee?: number;
  mentoriaPricing?: MentoriaPricingConfig;
  onClose: () => void;
  onSaved: () => void;
  onDeleted: () => void;
}) {
  const supabase = createClient();
  const isRentalEvent = !!event.rental_id;
  const isPendingReservation = !isRentalEvent && !!event.equipment_id && (event.status ?? "pre_reserva") === "pre_reserva";

  // Todos os hooks ficam aqui em cima, antes de qualquer return condicional
  // (regras de hooks do React: mesma quantidade e ordem em toda renderização,
  // independente de qual ramo — pendente, locação ou evento genérico — está
  // sendo mostrado). Cada ramo só usa o subconjunto que precisa.
  const [showFinalize, setShowFinalize] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [cancelError, setCancelError] = useState<string | null>(null);
  // Leva S: cancelar passa a pedir motivo/não-comparecimento e a ir pela
  // RPC cancelar_agendamento (bloqueia se já foi paga, vira taxa perdida
  // se a taxa estava paga) em vez do update direto de antes, que pulava
  // essas duas regras.
  const [showCancelForm, setShowCancelForm] = useState(false);
  const [cancelMotivo, setCancelMotivo] = useState("");
  const [cancelNoShow, setCancelNoShow] = useState(false);
  const [title, setTitle] = useState(event.title);
  const [localClients, setLocalClients] = useState(clients);
  const [clientId, setClientId] = useState(event.client_id ?? "");
  const [dateStart, setDateStart] = useState(event.date_start);
  const [notes, setNotes] = useState(event.notes ?? "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmarExclusao, setConfirmarExclusao] = useState(false);

  // Leva Z: "Gerar contrato" acessível direto da Agenda (antes só existia
  // na ficha do cliente), tanto para pré-reserva quanto para locação já
  // lançada — reaproveitando o mesmo GerarContratoModal/OrigemContrato de
  // lá, só buscando aqui os dados que a Agenda não carrega de cara.
  const [contratoState, setContratoState] = useState<{ origem: OrigemContrato; client: ClienteContratoInfo } | null>(
    null
  );
  const [loadingContrato, setLoadingContrato] = useState(false);
  const [contratoError, setContratoError] = useState<string | null>(null);

  // Leva Z: dados completos da locação, só existem quando o evento vem de
  // uma locação já lançada — buscados uma vez ao abrir, porque tanto o
  // contrato quanto o campo de deslocamento abaixo precisam deles.
  const [rentalDetails, setRentalDetails] = useState<RentalDetails | null>(null);
  const [loadingRental, setLoadingRental] = useState(false);
  const [kmIda, setKmIda] = useState("");
  const [savingDeslocamento, setSavingDeslocamento] = useState(false);
  const [deslocamentoError, setDeslocamentoError] = useState<string | null>(null);

  useEffect(() => {
    if (!isRentalEvent || !event.rental_id) return;
    let active = true;
    setLoadingRental(true);
    supabase
      .from("rentals")
      .select(
        "id, event_date, event_date_end, shots, calculated_value, payment_method, equipment_id, km_ida, valor_deslocamento, equipments(name, serial_number, anvisa_registro)"
      )
      .eq("id", event.rental_id)
      .single()
      .then(({ data }) => {
        if (!active) return;
        setLoadingRental(false);
        if (data) {
          const normalized: RentalDetails = {
            ...(data as any),
            equipments: Array.isArray((data as any).equipments)
              ? ((data as any).equipments[0] ?? null)
              : ((data as any).equipments ?? null),
          };
          setRentalDetails(normalized);
          setKmIda(normalized.km_ida ? String(normalized.km_ida) : "");
        }
      });
    return () => {
      active = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isRentalEvent, event.rental_id]);

  const kmIdaNumber = Number(kmIda.replace(/\D/g, "")) || 0;
  const valorDeslocamentoPreview = calcularValorDeslocamento(kmIdaNumber);

  // Leva Z: o deslocamento também precisa poder ser lançado já na
  // pré-reserva, antes de existir uma locação — o cliente pode pagar a
  // ajuda de custo adiantado. Busca o que já foi lançado nesta reserva
  // (a Agenda não carrega isso na lista principal) e, se ainda nada foi
  // lançado, começa em branco.
  const [loadingReservaDeslocamento, setLoadingReservaDeslocamento] = useState(false);
  const [kmIdaReserva, setKmIdaReserva] = useState("");
  const [savingDeslocamentoReserva, setSavingDeslocamentoReserva] = useState(false);
  const [deslocamentoReservaError, setDeslocamentoReservaError] = useState<string | null>(null);

  useEffect(() => {
    if (!isPendingReservation) return;
    let active = true;
    setLoadingReservaDeslocamento(true);
    supabase
      .from("calendar_events")
      .select("km_ida, valor_deslocamento")
      .eq("id", event.id)
      .single()
      .then(({ data }) => {
        if (!active) return;
        setLoadingReservaDeslocamento(false);
        if (data) {
          setKmIdaReserva(data.km_ida ? String(data.km_ida) : "");
        }
      });
    return () => {
      active = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isPendingReservation, event.id]);

  const kmIdaReservaNumber = Number(kmIdaReserva.replace(/\D/g, "")) || 0;
  const valorDeslocamentoReservaPreview = calcularValorDeslocamento(kmIdaReservaNumber);

  async function handleSalvarDeslocamentoReserva() {
    setSavingDeslocamentoReserva(true);
    setDeslocamentoReservaError(null);
    const { error } = await supabase.rpc("definir_deslocamento_reserva", {
      p_event_id: event.id,
      p_km_ida: kmIdaReservaNumber > 0 ? kmIdaReservaNumber : null,
      p_valor_deslocamento: valorDeslocamentoReservaPreview,
    });
    setSavingDeslocamentoReserva(false);
    if (error) {
      setDeslocamentoReservaError("Não foi possível salvar o deslocamento. Tente novamente.");
      return;
    }
    onSaved();
  }

  async function handleCancelReservation() {
    setCancelling(true);
    setCancelError(null);
    const { error } = await supabase.rpc("cancelar_agendamento", {
      p_event_id: event.id,
      p_motivo: cancelMotivo || null,
      p_no_show: cancelNoShow,
    });
    setCancelling(false);
    if (error) {
      setCancelError(error.message || "Não foi possível cancelar. Tente novamente.");
      return;
    }
    onDeleted();
  }

  async function handleAbrirContratoReserva() {
    if (!event.client_id) {
      setContratoError("Este agendamento não tem cliente vinculado.");
      return;
    }
    setLoadingContrato(true);
    setContratoError(null);
    const { data: clientData } = await supabase
      .from("clients")
      .select("id, name, email, document, address, display_name, contrato_nome, contrato_endereco")
      .eq("id", event.client_id)
      .single();
    const { data: equipmentData } = event.equipment_id
      ? await supabase
          .from("equipments")
          .select("name, serial_number, anvisa_registro")
          .eq("id", event.equipment_id)
          .single()
      : { data: null as EquipamentoContratoInfo | null };
    const { data: eventData } = await supabase.from("calendar_events").select("date_end").eq("id", event.id).single();
    setLoadingContrato(false);
    if (!clientData) {
      setContratoError("Não foi possível carregar os dados do cliente.");
      return;
    }
    setContratoState({
      client: clientData,
      origem: {
        kind: "reserva",
        reserva: {
          id: event.id,
          event_date: event.date_start,
          event_date_end: eventData?.date_end ?? null,
          equipment_id: event.equipment_id ?? "",
          equipments: equipmentData ?? null,
        },
      },
    });
  }

  async function handleAbrirContratoRental() {
    if (!event.client_id || !rentalDetails) {
      setContratoError("Ainda carregando os dados da locação. Tente de novo em instantes.");
      return;
    }
    setLoadingContrato(true);
    setContratoError(null);
    const { data: clientData } = await supabase
      .from("clients")
      .select("id, name, email, document, address, display_name, contrato_nome, contrato_endereco")
      .eq("id", event.client_id)
      .single();
    setLoadingContrato(false);
    if (!clientData) {
      setContratoError("Não foi possível carregar os dados do cliente.");
      return;
    }
    setContratoState({
      client: clientData,
      origem: {
        kind: "rental",
        rental: {
          id: rentalDetails.id,
          event_date: rentalDetails.event_date,
          event_date_end: rentalDetails.event_date_end,
          shots: rentalDetails.shots,
          calculated_value: rentalDetails.calculated_value,
          payment_method: rentalDetails.payment_method,
          equipment_id: rentalDetails.equipment_id,
          equipments: rentalDetails.equipments,
        },
      },
    });
  }

  async function handleSalvarDeslocamento() {
    if (!event.rental_id) return;
    setSavingDeslocamento(true);
    setDeslocamentoError(null);
    const { error } = await supabase.rpc("definir_deslocamento_locacao", {
      p_rental_id: event.rental_id,
      p_km_ida: kmIdaNumber > 0 ? kmIdaNumber : null,
      p_valor_deslocamento: valorDeslocamentoPreview,
    });
    setSavingDeslocamento(false);
    if (error) {
      setDeslocamentoError("Não foi possível salvar o deslocamento. Tente novamente.");
      return;
    }
    onSaved();
  }

  if (contratoState) {
    return (
      <GerarContratoModal
        origem={contratoState.origem}
        client={contratoState.client}
        pricingConfig={pricingConfig}
        onClose={() => setContratoState(null)}
      />
    );
  }

  if (isPendingReservation) {
    if (showFinalize) {
      return (
        <CalculadoraLocacaoModal
          mode={{
            kind: "finalize",
            reservation: {
              id: event.id,
              clientId: event.client_id ?? "",
              clientName: event.clients?.name ?? "Cliente",
              clientWhatsapp: event.clients?.whatsapp ?? null,
              taxaStatus: event.taxa_status,
              equipmentName: EQUIPMENT_LABELS[event.event_type] ?? event.event_type,
              eventDate: event.date_start,
            },
            isMentoria: event.is_mentoria ?? false,
          }}
          pricingConfig={pricingConfig}
          reservationFee={reservationFee}
          mentoriaPricing={mentoriaPricing}
          onClose={() => setShowFinalize(false)}
          onDone={onSaved}
        />
      );
    }

    return (
      <div className="fixed inset-0 z-20 flex items-end justify-center bg-black/40 sm:items-center" onClick={onClose}>
        <div
          className="w-full max-w-md rounded-t-2xl bg-white/90 p-6 shadow-2xl backdrop-blur-2xl dark:bg-neutral-900/85 sm:rounded-3xl"
          onClick={(e) => e.stopPropagation()}
        >
          <h2 className="mb-1 text-lg font-semibold text-neutral-900 dark:text-neutral-100">
            {event.is_mentoria ? "Mentoria pendente" : "Reserva pendente"}
          </h2>
          <p className="mb-4 text-sm text-neutral-500 dark:text-neutral-400">
            {EQUIPMENT_LABELS[event.event_type] ?? event.event_type} · {formatDate(event.date_start)}
            {event.clients?.name ? ` · ${event.clients.name}` : ""}
            <br />
            {event.is_mentoria
              ? "Ainda sem cobrança lançada. Finalize com a quantidade de pacientes modelo quando a mentoria acontecer, ou cancele se não for mais rolar."
              : "Ainda sem contagem de disparos. Finalize quando o procedimento acontecer, ou cancele se não for mais rolar."}
          </p>

          {cancelError && <p className="mb-3 text-sm text-red-600 dark:text-red-400">{cancelError}</p>}

          {showCancelForm ? (
            <div className="rounded-xl border border-red-200 p-3 dark:border-red-900/50">
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
              <div className="mt-3 flex gap-2">
                <button
                  onClick={() => setShowCancelForm(false)}
                  className="flex-1 rounded-xl border border-neutral-300 py-2 text-xs font-medium text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
                >
                  Voltar
                </button>
                <button
                  onClick={handleCancelReservation}
                  disabled={cancelling}
                  className="flex-1 rounded-xl bg-red-600 py-2 text-xs font-medium text-white disabled:opacity-60"
                >
                  {cancelling ? "Cancelando..." : "Confirmar cancelamento"}
                </button>
              </div>
            </div>
          ) : (
            <>
              <div className="flex gap-2">
                <button
                  onClick={onClose}
                  className="flex-1 rounded-xl border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
                >
                  Fechar
                </button>
                <button
                  onClick={() => setShowFinalize(true)}
                  className="flex-1 rounded-xl bg-brand-gradient py-2.5 text-sm font-medium text-white shadow-glow-teal transition hover:brightness-110 active:scale-[0.98]"
                >
                  {event.is_mentoria ? "Finalizar mentoria" : "Finalizar com disparos"}
                </button>
              </div>

              <div className="mt-3 rounded-xl border border-neutral-200 p-3 dark:border-neutral-700">
                <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">
                  Deslocamento — km de ida (opcional)
                </label>
                {loadingReservaDeslocamento ? (
                  <p className="text-xs text-neutral-400">Carregando...</p>
                ) : (
                  <>
                    <div className="flex items-center gap-2">
                      <input
                        inputMode="numeric"
                        value={kmIdaReserva}
                        onChange={(e) => setKmIdaReserva(e.target.value.replace(/\D/g, ""))}
                        placeholder="0"
                        className="w-28 rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
                      />
                      <button
                        onClick={handleSalvarDeslocamentoReserva}
                        disabled={savingDeslocamentoReserva}
                        className="rounded-lg border border-neutral-300 px-3 py-2 text-xs font-medium text-neutral-600 disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300"
                      >
                        {savingDeslocamentoReserva ? "Salvando..." : "Salvar"}
                      </button>
                    </div>
                    {valorDeslocamentoReservaPreview > 0 && (
                      <p className="mt-1 text-xs text-neutral-500">
                        {kmIdaReservaNumber} km ida · {kmIdaReservaNumber * 2} km ida e volta ={" "}
                        <strong>{formatCurrency(valorDeslocamentoReservaPreview)}</strong>
                      </p>
                    )}
                    <p className="mt-1 text-xs text-neutral-400">
                      Ajuda de custo que o cliente já pagou pelo deslocamento, mesmo antes do procedimento. Ao
                      finalizar a reserva, este valor segue junto para a locação.
                    </p>
                  </>
                )}
                {deslocamentoReservaError && (
                  <p className="mt-2 text-xs text-red-600 dark:text-red-400">{deslocamentoReservaError}</p>
                )}
              </div>

              {contratoError && <p className="mt-3 text-sm text-red-600 dark:text-red-400">{contratoError}</p>}

              <button
                onClick={handleAbrirContratoReserva}
                disabled={loadingContrato}
                className="mt-3 flex w-full items-center justify-center gap-1.5 rounded-xl border border-neutral-200 py-2.5 text-sm font-medium text-neutral-600 hover:border-brand-teal hover:text-brand-teal disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300"
              >
                <FileText size={14} strokeWidth={1.75} />
                {loadingContrato ? "Carregando..." : "Gerar contrato"}
              </button>

              <button
                onClick={() => setShowCancelForm(true)}
                className="mt-3 w-full rounded-xl border border-red-200 py-2.5 text-sm font-medium text-red-600 dark:border-red-900/50 dark:text-red-400"
              >
                Cancelar reserva
              </button>
            </>
          )}
        </div>
      </div>
    );
  }

  async function handleSave() {
    if (!title.trim() || !dateStart) {
      setError("Informe o título e a data.");
      return;
    }
    if (!window.confirm("Salvar essas alterações no evento?")) return;
    setSaving(true);
    setError(null);
    // Não altera event_type aqui: este ramo é só para evento genérico
    // sem equipamento ("outros" daqui em diante, ou um "mentoria" antigo
    // já existente antes desta trava). Mentoria nova sempre passa por
    // "Reservar HIPRO" (ver NovoEventoModal e ReservarHiproModal) para
    // manter o bloqueio de agenda pela constraint no_equipment_double_booking.
    const { error } = await supabase
      .from("calendar_events")
      .update({
        title: title.trim(),
        client_id: clientId || null,
        date_start: dateStart,
        date_end: dateStart,
        notes: notes || null,
      })
      .eq("id", event.id);
    setSaving(false);
    if (error) {
      setError("Não foi possível salvar. Tente novamente.");
      return;
    }
    onSaved();
  }

  if (isRentalEvent) {
    return (
      <div className="fixed inset-0 z-20 flex items-end justify-center bg-black/40 sm:items-center" onClick={onClose}>
        <div
          className="w-full max-w-md rounded-t-2xl bg-white/90 p-6 shadow-2xl backdrop-blur-2xl dark:bg-neutral-900/85 sm:rounded-3xl"
          onClick={(e) => e.stopPropagation()}
        >
          <h2 className="mb-1 text-lg font-semibold text-neutral-900 dark:text-neutral-100">{event.title}</h2>
          <p className="mb-4 text-sm text-neutral-500 dark:text-neutral-400">
            Este evento veio de uma locação HIPRO. Para editar cliente, data, equipamento, disparos ou valor, isso é
            feito na própria locação (na ficha do cliente), para manter o financeiro e a agenda sincronizados.
          </p>

          <div className="mb-4 rounded-xl border border-neutral-200 p-3 dark:border-neutral-700">
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">
              Deslocamento — km de ida (opcional)
            </label>
            {loadingRental ? (
              <p className="text-xs text-neutral-400">Carregando...</p>
            ) : (
              <>
                <div className="flex items-center gap-2">
                  <input
                    inputMode="numeric"
                    value={kmIda}
                    onChange={(e) => setKmIda(e.target.value.replace(/\D/g, ""))}
                    placeholder="0"
                    className="w-28 rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
                  />
                  <button
                    onClick={handleSalvarDeslocamento}
                    disabled={savingDeslocamento}
                    className="rounded-lg border border-neutral-300 px-3 py-2 text-xs font-medium text-neutral-600 disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300"
                  >
                    {savingDeslocamento ? "Salvando..." : "Salvar"}
                  </button>
                </div>
                {valorDeslocamentoPreview > 0 && (
                  <p className="mt-1 text-xs text-neutral-500">
                    {kmIdaNumber} km ida · {kmIdaNumber * 2} km ida e volta ={" "}
                    <strong>{formatCurrency(valorDeslocamentoPreview)}</strong>
                  </p>
                )}
                <p className="mt-1 text-xs text-neutral-400">
                  Ajuda de custo cobrada à parte do valor da locação, calculada em R$ 50 a cada 50 km de ida e volta.
                  Deixe em branco (ou zere) para remover um deslocamento lançado por engano.
                </p>
              </>
            )}
            {deslocamentoError && <p className="mt-2 text-xs text-red-600 dark:text-red-400">{deslocamentoError}</p>}
          </div>

          {contratoError && <p className="mb-3 text-sm text-red-600 dark:text-red-400">{contratoError}</p>}

          <button
            onClick={handleAbrirContratoRental}
            disabled={loadingContrato || loadingRental}
            className="mb-3 flex w-full items-center justify-center gap-1.5 rounded-xl border border-neutral-200 py-2.5 text-sm font-medium text-neutral-600 hover:border-brand-teal hover:text-brand-teal disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300"
          >
            <FileText size={14} strokeWidth={1.75} />
            {loadingContrato ? "Carregando..." : "Gerar contrato"}
          </button>

          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="flex-1 rounded-xl border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600 dark:border-neutral-700 dark:text-neutral-300"
            >
              Fechar
            </button>
            {event.client_id && (
              <Link
                href={`/clientes/${event.client_id}`}
                className="flex-1 rounded-xl bg-brand-teal py-2.5 text-center text-sm font-medium text-white transition hover:bg-brand-teal-dark"
              >
                Ir para a locação
              </Link>
            )}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 z-20 flex items-end justify-center bg-black/40 sm:items-center" onClick={onClose}>
      <div
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-t-2xl bg-white/90 p-6 shadow-2xl backdrop-blur-2xl dark:bg-neutral-900/85 sm:rounded-3xl"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="mb-4 text-lg font-semibold text-neutral-900 dark:text-neutral-100">Editar evento</h2>

        <div className="space-y-3">
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Título</label>
            <input
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            />
          </div>

          <ClientPicker
            clients={localClients}
            value={clientId}
            onChange={setClientId}
            onClientCreated={(c) => setLocalClients((prev) => [...prev, c])}
            optional
          />

          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-600 dark:text-neutral-400">Data</label>
            <input
              type="date"
              value={dateStart}
              onChange={(e) => setDateStart(e.target.value)}
              className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-100"
            />
          </div>

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

        <button
          onClick={() => setConfirmarExclusao(true)}
          className="mt-3 w-full rounded-xl border border-red-200 py-2.5 text-sm font-medium text-red-600 dark:border-red-900/50 dark:text-red-400"
        >
          Excluir evento
        </button>

        {/* Evento que pertence a uma locação faz a exclusão subir para a
            locação inteira, com o lançamento financeiro junto. A prévia
            avisa isso antes de confirmar. */}
        {confirmarExclusao && (
          <ConfirmarExclusaoModal
            table="calendar_events"
            id={event.id}
            onCancel={() => setConfirmarExclusao(false)}
            onDeleted={() => {
              setConfirmarExclusao(false);
              onDeleted();
            }}
          />
        )}
      </div>
    </div>
  );
}
