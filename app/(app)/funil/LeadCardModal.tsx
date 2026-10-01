// Dentro de LeadCardModal.tsx

// 1. Novo state, junto aos outros states do componente:
const [stats, setStats] = useState<{ concluidas: number; canceladas: number; reagendadas: number } | null>(null);

// 2. useEffect para carregar as contagens ao abrir o modal (adicionar perto dos outros hooks):
useEffect(() => {
  let active = true;
  async function carregarStats() {
    const [rentalsRes, reagendadasReservaRes] = await Promise.all([
      supabase.from("rentals").select("status, rescheduled").eq("client_id", lead.id),
      supabase
        .from("calendar_events")
        .select("id", { count: "exact", head: true })
        .eq("client_id", lead.id)
        .eq("rescheduled", true)
        .is("rental_id", null),
    ]);
    if (!active) return;
    const rentals = rentalsRes.data ?? [];
    setStats({
      concluidas: rentals.filter((r) => r.status === "realizada").length,
      canceladas: rentals.filter((r) => r.status === "cancelada").length,
      reagendadas: rentals.filter((r) => r.rescheduled).length + (reagendadasReservaRes.count ?? 0),
    });
  }
  carregarStats();
  return () => {
    active = false;
  };
}, [lead.id]);

// 3. JSX: renderizar a faixa de badges, logo abaixo do <h2> com o nome (antes do <div className="space-y-3">):
{stats && (
  <div className="mb-3 flex flex-wrap gap-2 text-xs">
    <span className="rounded-full bg-brand-teal/10 px-3 py-1 font-medium text-brand-teal">
      ✓ {stats.concluidas} concluída{stats.concluidas === 1 ? "" : "s"}
    </span>
    <span className="rounded-full bg-brand-pink/10 px-3 py-1 font-medium text-brand-pink">
      ✕ {stats.canceladas} cancelada{stats.canceladas === 1 ? "" : "s"}
    </span>
    <span className="rounded-full bg-brand-blue/10 px-3 py-1 font-medium text-brand-blue">
      ↻ {stats.reagendadas} reagendada{stats.reagendadas === 1 ? "" : "s"}
    </span>
  </div>
)}
