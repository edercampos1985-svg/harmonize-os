// Leva X: geração do PDF do contrato de locação, direto no navegador
// (nenhum arquivo fica salvo no servidor — só o retrato dos dados usados,
// em contratos_emitidos.dados). Isolado neste arquivo de propósito: é a
// ÚNICA peça que ainda precisa do texto real do contrato que a operação
// já usa fora do sistema. Por enquanto o corpo do contrato abaixo é um
// placeholder claramente marcado — as cláusulas de verdade (objeto,
// obrigações, garantias, foro etc.) entram aqui assim que o modelo for
// enviado, sem mexer em mais nenhum outro arquivo (o botão, o modal de
// conferência de dados e o controle de emitidos já funcionam de ponta a
// ponta usando este placeholder).
import { Document, Page, Text, View, StyleSheet, pdf, Font } from "@react-pdf/renderer";

export interface ContratoDados {
  contratante: {
    nome: string;
    documento: string;
    endereco: string | null;
  };
  equipamento: {
    nome: string;
    serial_number: string | null;
    anvisa_registro: string | null;
  };
  locacao: {
    event_date: string;
    event_date_end: string | null;
    shots: number;
    calculated_value: number;
    payment_method: string;
  };
  gerado_em: string;
}

const PAYMENT_LABELS: Record<string, string> = {
  pix: "PIX",
  dinheiro: "Dinheiro",
  debito: "Débito",
  credito: "Crédito",
  transferencia: "Transferência",
  outros: "Outros",
};

function formatDateBR(date: string): string {
  const d = new Date(`${date}T00:00:00`);
  return d.toLocaleDateString("pt-BR");
}

function formatPeriodo(d: ContratoDados["locacao"]): string {
  if (d.event_date_end && d.event_date_end !== d.event_date) {
    return `${formatDateBR(d.event_date)} a ${formatDateBR(d.event_date_end)}`;
  }
  return formatDateBR(d.event_date);
}

function formatCurrencyBR(value: number): string {
  return value.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
}

const styles = StyleSheet.create({
  page: { padding: 48, fontSize: 10.5, fontFamily: "Helvetica", lineHeight: 1.5, color: "#1a1a1a" },
  title: { fontSize: 14, fontFamily: "Helvetica-Bold", textAlign: "center", marginBottom: 4 },
  subtitle: { fontSize: 9, textAlign: "center", color: "#666", marginBottom: 20 },
  sectionTitle: { fontSize: 11, fontFamily: "Helvetica-Bold", marginTop: 16, marginBottom: 6 },
  row: { flexDirection: "row", marginBottom: 3 },
  label: { width: 110, fontFamily: "Helvetica-Bold" },
  value: { flex: 1 },
  paragraph: { marginBottom: 8, textAlign: "justify" },
  placeholderBox: {
    marginTop: 14,
    marginBottom: 14,
    padding: 10,
    borderWidth: 1,
    borderStyle: "dashed",
    borderColor: "#c0392b",
  },
  placeholderText: { color: "#c0392b", fontSize: 9.5 },
  signatures: { marginTop: 56, flexDirection: "row", justifyContent: "space-between" },
  signatureBlock: { width: "45%", alignItems: "center" },
  signatureLine: { borderTopWidth: 1, borderTopColor: "#1a1a1a", width: "100%", marginBottom: 4 },
  footer: { position: "absolute", bottom: 24, left: 48, right: 48, fontSize: 8, color: "#999", textAlign: "center" },
});

function ContratoDocument({ dados }: { dados: ContratoDados }) {
  return (
    <Document>
      <Page size="A4" style={styles.page}>
        <Text style={styles.title}>CONTRATO DE LOCAÇÃO DE EQUIPAMENTO</Text>
        <Text style={styles.subtitle}>Gerado em {formatDateBR(dados.gerado_em.slice(0, 10))}</Text>

        <Text style={styles.sectionTitle}>CONTRATANTE</Text>
        <View style={styles.row}>
          <Text style={styles.label}>Nome/Razão social</Text>
          <Text style={styles.value}>{dados.contratante.nome}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>CPF/CNPJ</Text>
          <Text style={styles.value}>{dados.contratante.documento}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Endereço</Text>
          <Text style={styles.value}>{dados.contratante.endereco || "-"}</Text>
        </View>

        <Text style={styles.sectionTitle}>OBJETO DA LOCAÇÃO</Text>
        <View style={styles.row}>
          <Text style={styles.label}>Equipamento</Text>
          <Text style={styles.value}>{dados.equipamento.nome}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Nº de série</Text>
          <Text style={styles.value}>{dados.equipamento.serial_number || "-"}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Registro ANVISA</Text>
          <Text style={styles.value}>{dados.equipamento.anvisa_registro || "-"}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Período</Text>
          <Text style={styles.value}>{formatPeriodo(dados.locacao)}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Disparos</Text>
          <Text style={styles.value}>{dados.locacao.shots.toLocaleString("pt-BR")}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Valor</Text>
          <Text style={styles.value}>{formatCurrencyBR(Number(dados.locacao.calculated_value))}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.label}>Forma de pagamento</Text>
          <Text style={styles.value}>{PAYMENT_LABELS[dados.locacao.payment_method] ?? dados.locacao.payment_method}</Text>
        </View>

        {/* PLACEHOLDER: as cláusulas reais (objeto detalhado, obrigações
            das partes, garantias, uso e conservação do equipamento,
            vigência, rescisão, foro etc.) entram aqui, substituindo este
            aviso, assim que o modelo de contrato usado pela operação for
            enviado. Nada mais neste fluxo (botão, modal, controle de
            emitidos) precisa mudar quando isso acontecer. */}
        <View style={styles.placeholderBox}>
          <Text style={styles.placeholderText}>
            [TEXTO DO CONTRATO PENDENTE — este é um documento provisório. As cláusulas oficiais (objeto, obrigações,
            garantias, vigência, rescisão, foro) entram aqui assim que o modelo usado pela operação for enviado.]
          </Text>
        </View>

        <View style={styles.signatures}>
          <View style={styles.signatureBlock}>
            <View style={styles.signatureLine} />
            <Text>Contratante</Text>
          </View>
          <View style={styles.signatureBlock}>
            <View style={styles.signatureLine} />
            <Text>Harmonize</Text>
          </View>
        </View>

        <Text style={styles.footer}>Documento gerado automaticamente pelo Harmonize OS — não é uma via assinada.</Text>
      </Page>
    </Document>
  );
}

/**
 * Gera o PDF do contrato inteiramente no navegador (sem passar por
 * nenhum servidor) e devolve um Blob pronto para download. Usado tanto na
 * geração original (GerarContratoModal) quanto no "baixar novamente" a
 * partir do retrato salvo em contratos_emitidos.dados.
 */
export async function gerarContratoPdfBlob(dados: ContratoDados): Promise<Blob> {
  return pdf(<ContratoDocument dados={dados} />).toBlob();
}

/**
 * Dispara o download do PDF no navegador a partir de um Blob já gerado.
 */
export function baixarPdfBlob(blob: Blob, nomeArquivo: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = nomeArquivo;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

/**
 * Nome de arquivo padrão para o download, já sem caracteres que
 * atrapalham em qualquer sistema de arquivos.
 */
export function nomeArquivoContrato(dados: ContratoDados): string {
  const nomeSanitizado = dados.contratante.nome.replace(/[^a-zA-Z0-9À-ÿ\s-]/g, "").trim().replace(/\s+/g, "-");
  return `Contrato-${nomeSanitizado}-${dados.locacao.event_date}.pdf`;
}
