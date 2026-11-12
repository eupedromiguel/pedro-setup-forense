#!/usr/bin/env bash
# =============================================================================
#  pedro-setup-forense.sh
#
#  Prepara uma VM Linux (Ubuntu 22.04/24.04, Debian ou Kali) como estação de
#  Forense Digital para laboratório:
#    - instala ferramentas de aquisição, análise de disco, carving, hashes,
#      malware, rede e artefatos Windows;
#    - desativa a montagem automática de mídias (proteção de evidências);
#    - cria utilitários de caso (pf-novo-caso, pf-nota, pf-hash,
#      pf-bloquear, pf-adquirir) e a pasta ~/forense;
#    - gera um inventário das ferramentas com versão e SHA-256 dos binários.
#
#  Autor  : Pedro Ataides
#  Versão : 1.0.0
#  Licença: MIT
#
#  Uso    : sudo ./pedro-setup-forense.sh [opções]
#             -n, --dry-run      mostra o que seria feito, sem alterar nada
#             -g, --sem-gui      não instala ferramentas gráficas
#             -p, --sem-python   não instala ferramentas Python (pipx)
#             -y, --sim          não pede confirmação
#             -h, --help         mostra esta ajuda
# =============================================================================
set -Eeuo pipefail

readonly VERSAO="1.0.0"
CARIMBO="$(date -u +%Y%m%dT%H%M%SZ)"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly CARIMBO SCRIPT_PATH
readonly TOTAL_ETAPAS=7
readonly REGRA_UDEV="/etc/udev/rules.d/99-pedro-forense-sem-automount.rules"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# --- Catálogo de pacotes: "Categoria|pacote pacote ..." ----------------------
CATALOGO=(
  "Base e utilitários|curl wget git jq unzip p7zip-full xxd hexedit sqlite3 file tree python3-pip pipx dosfstools mtools"
  "Aquisição e imagens|dc3dd dcfldd ewf-tools afflib-tools qemu-utils"
  "Disco e sistemas de arquivos|sleuthkit testdisk libvshadow-utils ntfs-3g"
  "Carving e metadados|foremost scalpel binwalk bulk-extractor libimage-exiftool-perl exiv2"
  "Hashes e integridade|hashdeep ssdeep"
  "Malware e IOCs|yara clamav chkrootkit rkhunter"
  "Rede|tshark tcpdump"
  "Artefatos Windows e e-mail|reglookup regripper pst-utils pff-tools"
)
CATALOGO_GUI=(
  "Interface gráfica|wireshark guymager autopsy ghex"
)
PIPX_PACOTES=(volatility3 oletools)

# Ferramentas do inventário: "binário|argumento de versão" ("-" = não executar)
FERRAMENTAS=(
  "dc3dd|--version"        "dcfldd|--version"     "ewfacquire|-V"
  "affinfo|-V"             "qemu-img|--version"   "mmls|-V"
  "fls|-V"                 "photorec|/version"    "vshadowinfo|-V"
  "foremost|-V"            "scalpel|-V"           "binwalk|--help"
  "bulk_extractor|-V"      "exiftool|-ver"        "exiv2|--version"
  "hashdeep|-V"            "ssdeep|-V"            "yara|--version"
  "clamscan|--version"     "chkrootkit|-V"        "rkhunter|--version"
  "tshark|--version"       "tcpdump|--version"    "reglookup|-"
  "regripper|-"            "readpst|-V"           "pffexport|-V"
  "vol|-"                  "olevba|-"             "wireshark|-"
  "guymager|-"             "autopsy|-"
)

# --- Estado -------------------------------------------------------------------
DRY_RUN=0; COM_GUI=1; COM_PY=1; ASSUMIR_SIM=0
ETAPA_ATUAL=0; DISTRO_ID=""; DISTRO_NOME=""; LOG=""; INVENTARIO=""
INSTALADOS=(); JA_PRESENTES=(); PULADOS=(); FALHAS=(); PY_OK=(); PARA_INSTALAR=()

USUARIO="${SUDO_USER:-$(id -un)}"
HOME_USUARIO="$(getent passwd "$USUARIO" | cut -d: -f6)"
GRUPO_USUARIO="$(id -gn "$USUARIO")"
DIR_FORENSE="$HOME_USUARIO/forense"

# --- Cores e mensagens ----------------------------------------------------------
RST=""; NEG=""; VERDE=""; AMARELO=""; VERMELHO=""; AZUL=""; CINZA=""
CORES256=0; UTF8=0; S_OK="+"; S_INFO="*"; S_AVISO="!"; S_ERRO="x"

configurar_cores() {
  if [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]]; then
    UTF8=1; S_OK="✔"; S_INFO="•"; S_AVISO="▲"; S_ERRO="✘"
  fi
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RST=$'\e[0m'; NEG=$'\e[1m'; VERDE=$'\e[32m'; AMARELO=$'\e[33m'
    VERMELHO=$'\e[31m'; AZUL=$'\e[36m'; CINZA=$'\e[90m'
    if (( $(tput colors 2>/dev/null || echo 8) >= 256 )); then CORES256=1; fi
  fi
}

registrar() {
  if [[ -n "$LOG" && -d "${LOG%/*}" ]]; then
    printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
  fi
}
info()  { printf '  %s%s%s %s\n' "$AZUL"     "$S_INFO"  "$RST" "$*";     registrar "INFO  $*"; }
ok()    { printf '  %s%s%s %s\n' "$VERDE"    "$S_OK"    "$RST" "$*";     registrar "OK    $*"; }
aviso() { printf '  %s%s%s %s\n' "$AMARELO"  "$S_AVISO" "$RST" "$*";     registrar "AVISO $*"; }
erro()  { printf '  %s%s%s %s\n' "$VERMELHO" "$S_ERRO"  "$RST" "$*" >&2; registrar "ERRO  $*"; }
etapa() {
  ETAPA_ATUAL=$((ETAPA_ATUAL + 1))
  printf '\n%s[%d/%d] %s%s\n' "$NEG" "$ETAPA_ATUAL" "$TOTAL_ETAPAS" "$*" "$RST"
  registrar "===== [$ETAPA_ATUAL/$TOTAL_ETAPAS] $*"
}

# Alinha texto pelo número de caracteres (printf %-Ns conta bytes e desalinha acentos).
alinhar() { local texto="$1" largura="$2"; printf '%s%*s' "$texto" $(( largura > ${#texto} ? largura - ${#texto} : 0 )) ""; }

# Executa um comando registrando tudo no log (ou só mostra, em --dry-run).
executar() {
  if (( DRY_RUN )); then
    printf '    %s[dry-run]%s %s\n' "$CINZA" "$RST" "$*"
    registrar "DRY   $*"
    return 0
  fi
  registrar "CMD   $*"
  "$@" >>"$LOG" 2>&1
}

# Executa como o usuário do laboratório (não root), na home dele.
como_usuario() {
  if [[ "$USUARIO" == "root" ]]; then
    "$@"
  else
    runuser -u "$USUARIO" -- env -C "$HOME_USUARIO" HOME="$HOME_USUARIO" \
      PATH="$HOME_USUARIO/.local/bin:$PATH" "$@"
  fi
}

confirmar() {
  if (( ASSUMIR_SIM || DRY_RUN )); then return 0; fi
  local resposta=""
  read -r -p "  $1 [s/N] " resposta || true
  [[ "$resposta" =~ ^[sS]([iI][mM])?$ ]]
}

ao_falhar() {
  local codigo=$? linha=$1
  erro "Falha inesperada na linha $linha (código $codigo). Detalhes em: ${LOG:-sem log}"
  exit "$codigo"
}
trap 'ao_falhar $LINENO' ERR

# --- Banner -------------------------------------------------------------------
mostrar_banner() {
  local -a nome lupa titulo grad
  if (( UTF8 )); then
    mapfile -t nome <<'ARTE'
██████╗ ███████╗██████╗ ██████╗  ██████╗
██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔═══██╗
██████╔╝█████╗  ██║  ██║██████╔╝██║   ██║
██╔═══╝ ██╔══╝  ██║  ██║██╔══██╗██║   ██║
██║     ███████╗██████╔╝██║  ██║╚██████╔╝
╚═╝     ╚══════╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝
ARTE
  else
    mapfile -t nome <<'ARTE'
 ____  _____ ____  ____   ___
|  _ \| ____|  _ \|  _ \ / _ \
| |_) |  _| | | | | |_) | | | |
|  __/| |___| |_| |  _ <| |_| |
|_|   |_____|____/|_| \_\\___/

ARTE
  fi
  mapfile -t lupa <<'ARTE'
   .-"""""-.
  / 0 1 0 1 \
 | 1 0 1 1 0 |
  \ 0 1 1 0 /
   '-.....-'\\
             \\
ARTE
  mapfile -t titulo <<'ARTE'
 ___      _               ___
/ __| ___| |_ _  _ _ __  | __|__ _ _ ___ _ _  ___ ___
\__ \/ -_)  _| || | '_ \ | _/ _ \ '_/ -_) ' \(_-</ -_)
|___/\___|\__|\_,_| .__/ |_|\___/_| \___|_||_/__/\___|
                  |_|
ARTE

  # Degradê ciano -> azul em terminais 256 cores; ciano simples nos demais.
  if (( CORES256 )); then
    grad=($'\e[38;5;51m' $'\e[38;5;45m' $'\e[38;5;39m' $'\e[38;5;33m' $'\e[38;5;27m' $'\e[38;5;21m')
  else
    grad=("$AZUL" "$AZUL" "$AZUL" "$AZUL" "$AZUL" "$AZUL")
  fi
  [[ -n "$RST" ]] || grad=("" "" "" "" "" "")

  echo
  local i
  for i in "${!nome[@]}"; do
    printf '%s%s%s  %s%s%s\n' "${grad[i]}" "${nome[i]}" "$RST" "$AMARELO" "${lupa[i]:-}" "$RST"
  done
  for i in "${!titulo[@]}"; do
    printf '%s%s%s\n' "$VERDE" "${titulo[i]}" "$RST"
  done
  printf '%s  Lab de Forense Digital  |  v%s  |  por Pedro Ataides%s\n' "$CINZA" "$VERSAO" "$RST"
}

# --- Opções -------------------------------------------------------------------
uso() {
  cat <<EOF
Uso: sudo ./$(basename "$SCRIPT_PATH") [opções]

  -n, --dry-run      mostra o que seria feito, sem alterar nada
  -g, --sem-gui      não instala ferramentas gráficas (wireshark, guymager...)
  -p, --sem-python   não instala ferramentas Python via pipx (volatility3...)
  -y, --sim          não pede confirmação
  -h, --help         mostra esta ajuda
EOF
}

ler_opcoes() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run)    DRY_RUN=1 ;;
      -g|--sem-gui)    COM_GUI=0 ;;
      -p|--sem-python) COM_PY=0 ;;
      -y|--sim)        ASSUMIR_SIM=1 ;;
      -h|--help)       uso; exit 0 ;;
      *) erro "Opção desconhecida: $1"; uso; exit 2 ;;
    esac
    shift
  done
}

preparar_log() {
  local dir="/var/log/pedro-setup-forense"
  if [[ $EUID -ne 0 ]]; then dir="/tmp/pedro-setup-forense"; fi
  mkdir -p "$dir"
  chmod 0750 "$dir"
  LOG="$dir/setup-$CARIMBO.log"
  : >"$LOG"
  registrar "pedro-setup-forense v$VERSAO | dry-run=$DRY_RUN gui=$COM_GUI python=$COM_PY | usuario=$USUARIO"
}

# --- 1. Ambiente ----------------------------------------------------------------
verificar_ambiente() {
  etapa "Verificando o ambiente"

  if (( ! DRY_RUN )) && [[ $EUID -ne 0 ]]; then
    erro "Execute com sudo: sudo $SCRIPT_PATH   (ou teste antes com --dry-run)"
    exit 1
  fi

  if [[ ! -r /etc/os-release ]]; then erro "Não encontrei /etc/os-release"; exit 1; fi
  local familia
  familia="$(. /etc/os-release && echo " ${ID:-} ${ID_LIKE:-} ")"
  DISTRO_ID="$(. /etc/os-release && echo "${ID:-}")"
  DISTRO_NOME="$(. /etc/os-release && echo "${PRETTY_NAME:-desconhecido}")"
  case "$familia" in
    *" ubuntu "*|*" debian "*|*" kali "*) ok "Sistema: $DISTRO_NOME" ;;
    *) erro "Sistema não suportado: $DISTRO_NOME (use Ubuntu, Debian ou Kali)"; exit 1 ;;
  esac
  if ! command -v apt-get >/dev/null; then erro "apt-get não encontrado"; exit 1; fi

  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in
    oracle)
      ok "VirtualBox detectado"
      info "Dica: tire um snapshot da VM antes de continuar (ex.: 'antes-setup-forense')" ;;
    none|"")
      aviso "Não parece ser uma VM. Este script foi pensado para um laboratório virtual."
      if ! confirmar "Continuar mesmo assim?"; then info "Cancelado."; exit 0; fi ;;
    *)
      ok "Virtualização detectada: $virt" ;;
  esac

  local livre
  livre="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"
  if (( livre < 20 )); then
    aviso "Pouco espaço livre em /: ${livre} GB (recomendado: 20 GB ou mais para ferramentas e imagens de teste)"
  else
    ok "Espaço livre em /: ${livre} GB"
  fi

  if [[ "$USUARIO" == "root" ]]; then
    aviso "Rodando como root direto: a pasta forense ficará em /root. Prefira 'sudo' a partir do seu usuário."
  else
    ok "Usuário do laboratório: $USUARIO ($HOME_USUARIO)"
  fi
  info "Log completo: $LOG"
}

# --- 2. Repositórios ------------------------------------------------------------
preparar_repositorios() {
  etapa "Atualizando repositórios"
  if [[ "$DISTRO_ID" == "ubuntu" ]] && \
     ! grep -rhsqE '^[^#]*\buniverse\b' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    info "Habilitando o repositório 'universe' (onde ficam várias ferramentas forenses)"
    executar apt-get "${APT_OPTS[@]}" install software-properties-common
    executar add-apt-repository -y universe
  fi
  info "Baixando índices de pacotes (acompanhe com: tail -f $LOG)"
  if executar apt-get "${APT_OPTS[@]}" update; then
    ok "Índices atualizados"
  else
    erro "apt-get update falhou — verifique a rede da VM (NAT) e o log"
    exit 1
  fi
}

# --- 3. Pacotes ---------------------------------------------------------------
pacote_instalado() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pacote_disponivel() {
  local candidato
  candidato="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')"
  [[ -n "$candidato" && "$candidato" != "(none)" ]]
}

instalar_pacotes() {
  etapa "Instalando ferramentas forenses"
  local -a catalogo=("${CATALOGO[@]}") lista
  local item categoria pacotes p novos
  if (( COM_GUI )); then catalogo+=("${CATALOGO_GUI[@]}"); else info "Ferramentas gráficas puladas (--sem-gui)"; fi

  for item in "${catalogo[@]}"; do
    IFS='|' read -r categoria pacotes <<<"$item"
    read -ra lista <<<"$pacotes"
    novos=0
    for p in "${lista[@]}"; do
      if pacote_instalado "$p"; then
        JA_PRESENTES+=("$p")
      elif pacote_disponivel "$p"; then
        PARA_INSTALAR+=("$p"); novos=$((novos + 1))
      else
        PULADOS+=("$p")
      fi
    done
    printf '    %s %2d pacote(s), %d a instalar\n' "$(alinhar "$categoria" 30)" "${#lista[@]}" "$novos"
  done

  if (( ${#PULADOS[@]} )); then aviso "Indisponíveis nesta distro (pulados): ${PULADOS[*]}"; fi
  if (( ${#PARA_INSTALAR[@]} == 0 )); then
    ok "Nada novo para instalar"
    return 0
  fi
  if (( DRY_RUN )); then
    executar apt-get "${APT_OPTS[@]}" install --no-install-recommends "${PARA_INSTALAR[@]}"
    info "Seriam instalados ${#PARA_INSTALAR[@]} pacotes"
    return 0
  fi

  info "Instalando ${#PARA_INSTALAR[@]} pacotes em lote (pode levar alguns minutos)..."
  if executar apt-get "${APT_OPTS[@]}" install --no-install-recommends "${PARA_INSTALAR[@]}"; then
    INSTALADOS+=("${PARA_INSTALAR[@]}")
  else
    aviso "A instalação em lote falhou — tentando pacote a pacote para isolar o problema"
    for p in "${PARA_INSTALAR[@]}"; do
      if executar apt-get "${APT_OPTS[@]}" install --no-install-recommends "$p"; then
        INSTALADOS+=("$p")
      else
        FALHAS+=("$p"); erro "Falhou: $p"
      fi
    done
  fi
  ok "Instalados agora: ${#INSTALADOS[@]} | já presentes: ${#JA_PRESENTES[@]}"
}

# --- 4. Python (pipx) -----------------------------------------------------------
instalar_python() {
  etapa "Instalando ferramentas Python (pipx)"
  if (( ! COM_PY )); then info "Pulado (--sem-python)"; return 0; fi
  if (( ! DRY_RUN )) && ! command -v pipx >/dev/null; then
    aviso "pipx não está disponível — pulando"; return 0
  fi
  local p
  for p in "${PIPX_PACOTES[@]}"; do
    if (( ! DRY_RUN )) && como_usuario pipx list --short 2>/dev/null | grep -qi "^$p "; then
      ok "$p (já instalado)"; PY_OK+=("$p"); continue
    fi
    if (( DRY_RUN )); then executar como_usuario pipx install "$p"; continue; fi
    info "pipx install $p (como $USUARIO)"
    if executar como_usuario pipx install "$p"; then
      ok "$p"; PY_OK+=("$p")
    else
      aviso "$p falhou (detalhes no log)"; FALHAS+=("pipx:$p")
    fi
  done
  executar como_usuario pipx ensurepath || true
}

# --- 5. Proteção de evidências ----------------------------------------------------
configurar_protecoes() {
  etapa "Protegendo evidências (sem montagem automática de mídias)"
  if (( DRY_RUN )); then
    info "[dry-run] criaria $REGRA_UDEV"
  else
    mkdir -p "${REGRA_UDEV%/*}"
    cat >"$REGRA_UDEV" <<'EOF'
# pedro-setup-forense: mídias conectadas NÃO são montadas automaticamente.
# Montar uma evidência por engano pode alterá-la (journal, horários de acesso...).
# Para desfazer: sudo rm este arquivo && sudo udevadm control --reload-rules
SUBSYSTEM=="block", ENV{UDISKS_AUTO}="0"
EOF
    ok "Regra udev criada: $REGRA_UDEV"
  fi
  if command -v udevadm >/dev/null; then
    executar udevadm control --reload-rules || aviso "Não deu para recarregar o udev agora; a regra vale após reiniciar"
  fi

  # Ambientes gráficos (GNOME no Ubuntu, XFCE no Kali): ajusta se houver sessão ativa.
  local uid barramento
  uid="$(id -u "$USUARIO")"; barramento="/run/user/$uid/bus"
  if [[ -S "$barramento" ]]; then
    if command -v gsettings >/dev/null; then
      executar como_usuario env DBUS_SESSION_BUS_ADDRESS="unix:path=$barramento" \
        gsettings set org.gnome.desktop.media-handling automount false || true
      executar como_usuario env DBUS_SESSION_BUS_ADDRESS="unix:path=$barramento" \
        gsettings set org.gnome.desktop.media-handling automount-open false || true
      ok "GNOME: montagem/abertura automática desativadas"
    fi
    if command -v xfconf-query >/dev/null; then
      executar como_usuario env DBUS_SESSION_BUS_ADDRESS="unix:path=$barramento" \
        xfconf-query -c thunar-volman -p /automount-drives/enabled -n -t bool -s false || true
      ok "XFCE: montagem automática desativada"
    fi
  else
    info "Sem sessão gráfica ativa agora — a regra udev já cobre a montagem automática"
  fi
}

# --- 6. Utilitários pf-* e pasta ~/forense ----------------------------------------
criar_dir() {
  if (( DRY_RUN )); then info "[dry-run] criaria $1"; return 0; fi
  install -d -m 0750 -o "$USUARIO" -g "$GRUPO_USUARIO" "$1"
}

instalar_utilitario() {
  local destino="/usr/local/bin/$1"
  if (( DRY_RUN )); then
    cat >/dev/null
    info "[dry-run] criaria $destino"
    return 0
  fi
  cat >"$destino"
  chmod 0755 "$destino"
  ok "$1"
}

instalar_utilitarios() {
  etapa "Criando utilitários de caso (pf-*) e a pasta ~/forense"
  criar_dir "$DIR_FORENSE"
  criar_dir "$DIR_FORENSE/casos"
  criar_dir "$DIR_FORENSE/inventario"

  instalar_utilitario pf-novo-caso <<'UTIL'
#!/usr/bin/env bash
# pf-novo-caso — cria a estrutura padrão de um caso forense (lab "Pedro - Setup Forense")
set -euo pipefail
if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Uso: pf-novo-caso <ID-DO-CASO> [nome do examinador]"
  echo "Ex.: pf-novo-caso CASO-001 \"Pedro\""
  exit 1
fi
if [[ $EUID -eq 0 ]]; then echo "Rode sem sudo (o caso fica na sua home)." >&2; exit 1; fi
caso_id="$1"
examinador="${2:-$(id -un)}"
if [[ ! "$caso_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ID inválido: use letras, números, ponto, hífen ou sublinhado." >&2; exit 1
fi
caso="${PF_BASE:-$HOME/forense/casos}/$caso_id"
if [[ -e "$caso" ]]; then echo "O caso já existe: $caso" >&2; exit 1; fi
agora="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$caso"/{00_admin,01_evidencias,02_imagens,03_exportados,04_analise,05_relatorio}
chmod 0750 "$caso"

cat >"$caso/00_admin/cadeia-de-custodia.md" <<MODELO
# Cadeia de Custódia — Caso $caso_id

> Referências: CPP, arts. 158-A a 158-F (Lei 13.964/2019) · ABNT NBR ISO/IEC 27037
> Todos os horários em UTC.

## Identificação
| Campo | Valor |
|---|---|
| Caso | $caso_id |
| Aberto em (UTC) | $agora |
| Examinador(a) | $examinador |
| Estação de análise | $(hostname) |

## Itens de evidência
| Item | Descrição | Identificação (modelo / nº de série) | Coletado por | Data/hora (UTC) | Local da coleta | Lacre | SHA-256 |
|---|---|---|---|---|---|---|---|
| E01 |  |  |  |  |  |  |  |

## Registro de transferências (posse)
| Data/hora (UTC) | Item | Entregue por | Recebido por | Finalidade |
|---|---|---|---|---|
|  |  |  |  |  |

## Assinaturas
Examinador(a): ________________________________   Data: ___/___/______

Testemunha 1: _________________________________   Documento: ______________

Testemunha 2: _________________________________   Documento: ______________
MODELO

cat >"$caso/00_admin/notas-do-caso.md" <<MODELO
# Notas do caso $caso_id
- Aberto em (UTC): $agora
- Examinador(a): $examinador

## Pergunta a responder

## Hipóteses

## Linha do tempo (UTC)
| Data/hora | Fonte | Evento |
|---|---|---|

## Achados

## Conclusão
MODELO

printf '%s | %s | Caso aberto por %s\n' "$agora" "$(id -un)" "$examinador" >"$caso/00_admin/log-de-acoes.log"
echo "Caso criado: $caso"
echo
echo "Ative o caso neste terminal com:"
echo "  export PF_CASO=\"$caso\""
UTIL

  instalar_utilitario pf-nota <<'UTIL'
#!/usr/bin/env bash
# pf-nota — registra uma ação no log do caso ativo, com horário UTC
set -euo pipefail
if [[ -z "${PF_CASO:-}" ]]; then echo "Defina o caso ativo: export PF_CASO=~/forense/casos/<ID>" >&2; exit 1; fi
if [[ $# -lt 1 ]]; then echo 'Uso: pf-nota "o que foi feito"' >&2; exit 1; fi
printf '%s | %s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-$(id -un)}" "$*" \
  | tee -a "$PF_CASO/00_admin/log-de-acoes.log"
UTIL

  instalar_utilitario pf-hash <<'UTIL'
#!/usr/bin/env bash
# pf-hash — MD5, SHA-1 e SHA-256 numa única leitura; registra no caso ativo (se houver)
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "Uso: pf-hash <arquivo> [arquivo...]"
  echo "Com PF_CASO definido, registra em \$PF_CASO/00_admin/hashes.tsv"
  exit 1
fi
registro=""
if [[ -n "${PF_CASO:-}" ]]; then
  registro="$PF_CASO/00_admin/hashes.tsv"
  if [[ ! -f "$registro" ]]; then printf 'utc\tsha256\tsha1\tmd5\tbytes\tarquivo\n' >"$registro"; fi
fi
for arq in "$@"; do
  if [[ ! -f "$arq" || ! -r "$arq" ]]; then echo "Ignorado (não é um arquivo legível): $arq" >&2; continue; fi
  caminho="$(readlink -f "$arq")"
  if command -v hashdeep >/dev/null; then
    IFS=, read -r bytes md5 sha1 sha256 _ < <(hashdeep -c md5,sha1,sha256 -s "$caminho" | grep -v '^[%#]')
  else
    bytes="$(stat -c %s "$caminho")"
    md5="$(md5sum "$caminho" | cut -d' ' -f1)"
    sha1="$(sha1sum "$caminho" | cut -d' ' -f1)"
    sha256="$(sha256sum "$caminho" | cut -d' ' -f1)"
  fi
  printf 'Arquivo : %s\nBytes   : %s\nMD5     : %s\nSHA-1   : %s\nSHA-256 : %s\n\n' \
    "$caminho" "$bytes" "$md5" "$sha1" "$sha256"
  if [[ -n "$registro" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$sha256" "$sha1" "$md5" "$bytes" "$caminho" >>"$registro"
  fi
done
UTIL

  instalar_utilitario pf-bloquear <<'UTIL'
#!/usr/bin/env bash
# pf-bloquear — bloqueio de escrita por software (blockdev --setro) no disco e partições
set -euo pipefail
if [[ $# -ne 1 || ! -b "${1:-}" ]]; then echo "Uso: sudo pf-bloquear /dev/sdX" >&2; exit 1; fi
if [[ $EUID -ne 0 ]]; then echo "Precisa de root: sudo pf-bloquear $1" >&2; exit 1; fi
mapfile -t alvos < <(lsblk -lnpo NAME "$1")
for alvo in "${alvos[@]}"; do
  if findmnt -rno TARGET -S "$alvo" >/dev/null 2>&1; then
    echo "ATENÇÃO: $alvo está montado em $(findmnt -rno TARGET -S "$alvo") — desmonte antes de analisar." >&2
  fi
  blockdev --setro "$alvo"
  if [[ "$(blockdev --getro "$alvo")" == "1" ]]; then
    printf '%-18s somente leitura: SIM\n' "$alvo"
  else
    printf '%-18s somente leitura: NÃO (verifique!)\n' "$alvo" >&2; exit 2
  fi
done
echo "Obs.: o bloqueio por software complementa, mas não substitui, um write-blocker físico."
UTIL

  instalar_utilitario pf-adquirir <<'UTIL'
#!/usr/bin/env bash
# pf-adquirir — aquisição forense com dc3dd: bloqueia, copia, calcula e confere o SHA-256
set -euo pipefail
if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Uso: sudo -E pf-adquirir <origem: /dev/sdX ou arquivo> [nome-da-imagem.dd]"
  echo "Com PF_CASO definido (sudo -E preserva), a imagem vai para \$PF_CASO/02_imagens"
  exit 1
fi
origem="$1"
if [[ ! -e "$origem" ]]; then echo "Origem não existe: $origem" >&2; exit 1; fi
command -v dc3dd >/dev/null || { echo "dc3dd não encontrado" >&2; exit 1; }

if [[ -b "$origem" ]]; then
  if [[ $EUID -ne 0 ]]; then echo "Dispositivo de bloco exige root: sudo -E pf-adquirir $origem" >&2; exit 1; fi
  pf-bloquear "$origem"
  tamanho="$(blockdev --getsize64 "$origem")"
else
  echo "Origem é um arquivo (modo treino) — sem bloqueio de escrita."
  tamanho="$(stat -c %s "$origem")"
fi

destino_dir="${PF_CASO:+$PF_CASO/02_imagens}"
destino_dir="${destino_dir:-$PWD}"
nome="${2:-$(basename "$origem")-$(date -u +%Y%m%dT%H%M%SZ).dd}"
imagem="$destino_dir/$nome"
log="$imagem.log"
if [[ -e "$imagem" ]]; then echo "Já existe: $imagem" >&2; exit 1; fi

livre="$(df -B1 --output=avail "$destino_dir" | tail -n1 | tr -dc '0-9')"
if (( livre < tamanho )); then
  echo "Espaço insuficiente em $destino_dir: precisa de $tamanho bytes, há $livre" >&2; exit 1
fi

inicio="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
dc3dd if="$origem" of="$imagem" hash=sha256 log="$log"

hash_origem="$(grep -oiE '\b[0-9a-f]{64}\b' "$log" | head -n1 | tr 'A-F' 'a-f')"
echo "Conferindo a imagem (recalculando o SHA-256)..."
hash_imagem="$(sha256sum "$imagem" | cut -d' ' -f1)"
printf '%s  %s\n' "$hash_imagem" "$nome" >"$imagem.sha256"

if [[ -n "${SUDO_USER:-}" ]]; then chown "$SUDO_USER": "$imagem" "$log" "$imagem.sha256" 2>/dev/null || true; fi

if [[ -n "$hash_origem" && "$hash_origem" == "$hash_imagem" ]]; then
  resultado="OK — SHA-256 da origem e da imagem conferem ($hash_imagem)"
  codigo=0
else
  resultado="FALHA — SHA-256 divergente (origem: ${hash_origem:-?} | imagem: $hash_imagem)"
  codigo=2
fi
echo "$resultado"

if [[ -n "${PF_CASO:-}" ]]; then
  printf '%s | %s | Aquisição de %s -> %s | início %s | %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-$(id -un)}" "$origem" "$imagem" "$inicio" "$resultado" \
    >>"$PF_CASO/00_admin/log-de-acoes.log"
fi
exit "$codigo"
UTIL
}

# --- 7. Inventário --------------------------------------------------------------
versao_de() {
  local bin="$1" arg="$2" saida
  saida="$(timeout 10 "$bin" "$arg" 2>&1 </dev/null || true)"
  saida="$(grep -m1 -oE '[0-9]+(\.[0-9]+)+|[0-9]{8}' <<<"$saida" | head -n1 || true)"
  echo "${saida:-?}"
}

# Pacote de origem do binário: dpkg (apt) ou o venv do pipx.
pacote_do_binario() {
  local pacote venv info
  pacote="$(dpkg -S "$1" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  if [[ -n "$pacote" ]]; then
    echo "$pacote $(dpkg-query -W -f='${Version}' "$pacote" 2>/dev/null)"
  elif [[ "$1" =~ ^(.*/pipx/venvs/([^/]+))/ ]]; then
    venv="${BASH_REMATCH[1]}"; pacote="${BASH_REMATCH[2]}"
    info="$(compgen -G "$venv/lib/python3*/site-packages/${pacote//-/_}-*.dist-info" | head -n1 || true)"
    info="${info##*/}"; info="${info%.dist-info}"
    echo "pipx ${pacote} ${info##*-}"
  else
    echo "?"
  fi
}

gerar_inventario() {
  etapa "Gerando inventário de ferramentas (versão + SHA-256)"
  INVENTARIO="$DIR_FORENSE/inventario/inventario-ferramentas-$CARIMBO.md"
  if (( DRY_RUN )); then info "[dry-run] geraria $INVENTARIO"; return 0; fi

  local item bin arg caminho real versao pacote hash encontradas=0
  local -a ausentes=()
  {
    echo "# Inventário de ferramentas — estação forense"
    echo
    echo "- Gerado em (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Host: $(hostname)"
    echo "- Sistema: $DISTRO_NOME | kernel $(uname -r)"
    echo "- Script: pedro-setup-forense.sh v$VERSAO | SHA-256 $(sha256sum "$SCRIPT_PATH" | cut -d' ' -f1)"
    echo
    echo "| Ferramenta | Versão | Pacote | Caminho | SHA-256 do binário |"
    echo "|---|---|---|---|---|"
  } >"$INVENTARIO"

  for item in "${FERRAMENTAS[@]}"; do
    IFS='|' read -r bin arg <<<"$item"
    caminho="$(PATH="$HOME_USUARIO/.local/bin:$PATH" command -v "$bin" || true)"
    if [[ -z "$caminho" ]]; then ausentes+=("$bin"); continue; fi
    real="$(readlink -f "$caminho")"
    if [[ "$arg" == "-" ]]; then versao="—"; else versao="$(versao_de "$caminho" "$arg")"; fi
    pacote="$(pacote_do_binario "$real")"
    hash="$(sha256sum "$real" | cut -d' ' -f1)"
    printf '| %s | %s | %s | `%s` | `%s` |\n' "$bin" "$versao" "$pacote" "$caminho" "$hash" >>"$INVENTARIO"
    encontradas=$((encontradas + 1))
  done

  if (( ${#ausentes[@]} )); then
    printf '\nNão encontradas nesta estação: %s\n' "${ausentes[*]}" >>"$INVENTARIO"
  fi
  chown "$USUARIO:$GRUPO_USUARIO" "$INVENTARIO"
  ok "$encontradas ferramentas inventariadas"
  ok "Inventário: $INVENTARIO"
}

# --- Resumo -------------------------------------------------------------------
resumo() {
  local min=$((SECONDS / 60)) seg=$((SECONDS % 60))
  printf '\n%s================  RESUMO  ================%s\n' "$NEG" "$RST"
  if (( DRY_RUN )); then
    aviso "Modo dry-run: nada foi alterado."
    info "Seriam instalados: ${#PARA_INSTALAR[@]} pacotes | já presentes: ${#JA_PRESENTES[@]}"
  else
    ok "Pacotes instalados agora: ${#INSTALADOS[@]} | já presentes: ${#JA_PRESENTES[@]}"
  fi
  if (( ${#PY_OK[@]} )); then ok "Ferramentas Python: ${PY_OK[*]}"; fi
  if (( ${#PULADOS[@]} )); then aviso "Indisponíveis nesta distro: ${PULADOS[*]}"; fi
  if (( ${#FALHAS[@]} )); then erro "Falharam: ${FALHAS[*]} (veja o log)"; fi
  info "Log: $LOG"
  if [[ -n "$INVENTARIO" && -f "$INVENTARIO" ]]; then info "Inventário: $INVENTARIO"; fi
  info "Tempo total: ${min}min ${seg}s"

  cat <<EOF

${NEG}Próximos passos${RST}
  1. Reinicie a VM e tire um snapshot "forense-baseline" (estado limpo de referência).
  2. Durante as análises, deixe a rede da VM em "Não conectado" ou "Host-only".
  3. Abra um novo terminal (para o PATH do pipx valer) e crie seu primeiro caso:
       pf-novo-caso CASO-001 "Pedro"
       export PF_CASO=~/forense/casos/CASO-001
       pf-nota "Início da análise"
EOF
}

main() {
  ler_opcoes "$@"
  configurar_cores
  preparar_log
  mostrar_banner
  if (( DRY_RUN )); then echo; aviso "Modo DRY-RUN: nada será alterado"; fi
  verificar_ambiente
  preparar_repositorios
  instalar_pacotes
  instalar_python
  configurar_protecoes
  instalar_utilitarios
  gerar_inventario
  resumo
}

main "$@"
