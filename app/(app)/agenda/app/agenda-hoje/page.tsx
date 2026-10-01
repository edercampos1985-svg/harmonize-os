import { createClient } from "@/lib/supabase/server";
import { formatDate } from "@/lib/format";

export const dynamic = "force-dynamic";

export default async function AgendaHojePage() {
  const supabase = await createClient();

  const hojeStr = new Date().toISOString().slice(0, 10);

  const { data: rentals } = await supabase
    .from("rentals")
    .select("id, event_date, event_date_end, clients(name)")
    .eq("is_test", false)
    .neq("status", "cancelada")
    .gte("event_date", hojeStr)
    .order("event_date", { ascending: true })
    .limit(50);

  const lista = rentals ?? [];

  return (
    <div className="min-h-screen bg-neutral-50 p-4">
      <h1 className="mb-4 text-lg font-semibold text-neutral-900">Próximas locações</h1>

      {lista.length === 0 && (
        <p className="text-sm text-neutral-400">Nenhuma locação futura.</p>
      )}

      <ul className="space-y-2">
        {lista.map((r: any) => (
          <li
            key={r.id}
            className="rounded-xl border border-neutral-200 bg-white p-3 shadow-sm"
          >
            <p className="text-sm font-medium text-neutral-900">
              {r.clients?.name ?? "-"}
            </p>
            <p className="text-xs text-neutral-500">
              {r.event_date_end && r.event_date_end !== r.event_date
                ? `${formatDate(r.event_date)} a ${formatDate(r.event_date_end)}`
                : formatDate(r.event_date)}
            </p>
          </li>
        ))}
      </ul>
    </div>
  );
}
