import { createClient } from "@/lib/supabase/server";
import { formatDate } from "@/lib/format";
import { hojeLocal } from "@/lib/period";

export const dynamic = "force-dynamic";

function nomeEquipamento(eq: any): string | null {
  const e = Array.isArray(eq) ? eq[0] : eq;
  return e?.name ?? null;
}

export default async function AgendaHojePage() {
  const supabase = await createClient();

  // Dia de Brasília: com UTC, depois das 21h "hoje" já virava amanhã.
  const hojeStr = hojeLocal();

  // Locações já finalizadas (com disparos/valor lançados) a partir de hoje.
  const { data: rentals } = await supabase
    .from("rentals")
    .select("id, event_date, event_date_end, clients(name), equipments(name)")
    .eq("is_test", false)
    .neq("status", "cancelada")
    .gte("event_date", hojeStr)
    .order("event_date", { ascending: true })
    .limit(50);

  // Pré-reservas ("Agendar sem disparos") que ainda não viraram locação —
  // ficam em calendar_events, não em rentals, e são justamente os
  // "próximos agendamentos" que ainda não têm disparos contados.
  const { data: preReservas } = await supabase
    .from("calendar_events")
    .select("id, date_start, date_end, clients(name), equipments(name)")
    .eq("is_test", false)
    .eq("status", "pre_reserva")
    .is("rental_id", null)
    .gte("date_start", hojeStr)
    .order("date_start", { ascending: true })
    .limit(50);

  const listaRentals = (rentals ?? []).map((r: any) => ({
    id: `rental-${r.id}`,
    data_inicio: r.event_date,
    data_fim: r.event_date_end,
    cliente: Array.isArray(r.clients) ? (r.clients[0]?.name ?? null) : (r.clients?.name ?? null),
    equipamento: nomeEquipamento(r.equipments),
    pendente: false,
  }));

  const listaPreReservas = (preReservas ?? []).map((r: any) => ({
    id: `reserva-${r.id}`,
    data_inicio: r.date_start,
    data_fim: r.date_end,
    cliente: Array.isArray(r.clients) ? (r.clients[0]?.name ?? null) : (r.clients?.name ?? null),
    equipamento: nomeEquipamento(r.equipments),
    pendente: true,
  }));

  const lista = [...listaRentals, ...listaPreReservas].sort((a, b) =>
    a.data_inicio.localeCompare(b.data_inicio)
  );

  return (
    <div className="min-h-screen bg-neutral-50 p-4 dark:bg-neutral-950">
      <h1 className="mb-4 text-lg font-semibold text-neutral-900 dark:text-neutral-100">Próximos agendamentos</h1>

      {lista.length === 0 && (
        <p className="text-sm text-neutral-400">Nenhum agendamento futuro.</p>
      )}

      <ul className="space-y-2">
        {lista.map((r) => (
          <li
            key={r.id}
            className="rounded-xl border border-neutral-200 bg-white p-3 shadow-sm dark:border-neutral-800 dark:bg-neutral-900"
          >
            <div className="flex items-center justify-between gap-2">
              <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">{r.cliente ?? "-"}</p>
              {r.pendente && (
                <span className="rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                  sem disparos ainda
                </span>
              )}
            </div>
            <p className="text-xs text-neutral-500 dark:text-neutral-400">
              {r.equipamento ? `${r.equipamento} · ` : ""}
              {r.data_fim && r.data_fim !== r.data_inicio
                ? `${formatDate(r.data_inicio)} a ${formatDate(r.data_fim)}`
                : formatDate(r.data_inicio)}
            </p>
          </li>
        ))}
      </ul>
    </div>
  );
}
