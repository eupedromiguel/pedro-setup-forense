#!/usr/bin/env bash
# =============================================================================
#  pedro-setup-forense.sh
#
#  Prepara uma VM Linux (Ubuntu 22.04/24.04, Debian ou Kali) como estação de
#  Forense Digital para laboratório:
#    - instala ferramentas de aquisição, análise de disco, carving, hashes,
#      malware, rede e artefatos Windows;
#    - desativa o swap (dados de evidência não vão parar no disco da estação);
#    - protege evidências: sem montagem automática, discos USB em somente
#      leitura no kernel e montagens do udisks em somente leitura;
#    - cria utilitários de caso (pf-novo-caso, pf-nota, pf-hash,
#      pf-bloquear, pf-montar, pf-adquirir) e a pasta ~/forense;
#    - valida a integridade do sistema (dpkg --verify, rkhunter, chkrootkit);
#    - gera um inventário das ferramentas com versão e SHA-256 dos binários.
#
#  Autor  : Pedro Ataides
#  Versão : 1.1.0
#  Licença: MIT
#
#  Uso    : sudo ./pedro-setup-forense.sh [opções]
#             -n, --dry-run          mostra o que seria feito, sem alterar nada
#             -g, --sem-gui          não instala ferramentas gráficas
#             -p, --sem-python       não instala ferramentas Python (pipx)
#             -s, --manter-swap      não desativa o swap
#             -i, --sem-verificacao  não valida a integridade do sistema
#             -y, --sim              não pede confirmação
#             -h, --help             mostra esta ajuda
# =============================================================================
set -Eeuo pipefail

readonly VERSAO="1.1.0"
CARIMBO="$(date -u +%Y%m%dT%H%M%SZ)"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly CARIMBO SCRIPT_PATH
readonly TOTAL_ETAPAS=9
readonly REGRA_UDEV="/etc/udev/rules.d/99-pedro-forense-sem-automount.rules"
readonly REGRA_UDEV_RO="/etc/udev/rules.d/99-pedro-forense-usb-somente-leitura.rules"
readonly UDISKS_CONF="/etc/udisks2/mount_options.conf"
readonly FSTAB="/etc/fstab"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# --- Catálogo de pacotes: "Categoria|pacote pacote ..." ----------------------
# "a/b" = alternativas: usa a primeira já instalada ou disponível na distro
# (ex.: o Kali trocou o p7zip-full pelo pacote 7zip).
CATALOGO=(
  "Base e utilitários|curl wget git jq unzip p7zip-full/7zip xxd hexedit sqlite3 file tree python3-pip pipx dosfstools mtools"
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
DRY_RUN=0; COM_GUI=1; COM_PY=1; ASSUMIR_SIM=0; DESATIVAR_SWAP=1; VERIFICAR=1
ETAPA_ATUAL=0; DISTRO_ID=""; DISTRO_NOME=""; LOG=""; INVENTARIO=""
RELATORIO_INTEGRIDADE=""; RESUMO_INTEGRIDADE=(); RESUMO_SWAP=""
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

  -n, --dry-run          mostra o que seria feito, sem alterar nada
  -g, --sem-gui          não instala ferramentas gráficas (wireshark, guymager...)
  -p, --sem-python       não instala ferramentas Python via pipx (volatility3...)
  -s, --manter-swap      não desativa o swap
  -i, --sem-verificacao  não valida a integridade do sistema (dpkg/rkhunter/chkrootkit)
  -y, --sim              não pede confirmação
  -h, --help             mostra esta ajuda

Rode ANTES de conectar qualquer evidência à VM.
EOF
}

ler_opcoes() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run)    DRY_RUN=1 ;;
      -g|--sem-gui)    COM_GUI=0 ;;
      -p|--sem-python) COM_PY=0 ;;
      -s|--manter-swap)     DESATIVAR_SWAP=0 ;;
      -i|--sem-verificacao) VERIFICAR=0 ;;
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
  registrar "pedro-setup-forense v$VERSAO | dry-run=$DRY_RUN gui=$COM_GUI python=$COM_PY swap-off=$DESATIVAR_SWAP verificacao=$VERIFICAR | usuario=$USUARIO"
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
  local item categoria pacotes entrada p alt novos
  local -a alternativas
  if (( COM_GUI )); then catalogo+=("${CATALOGO_GUI[@]}"); else info "Ferramentas gráficas puladas (--sem-gui)"; fi

  for item in "${catalogo[@]}"; do
    IFS='|' read -r categoria pacotes <<<"$item"
    read -ra lista <<<"$pacotes"
    novos=0
    for entrada in "${lista[@]}"; do
      IFS='/' read -ra alternativas <<<"$entrada"
      p=""
      # 1º: alguma alternativa já instalada; 2º: a primeira disponível.
      for alt in "${alternativas[@]}"; do
        if pacote_instalado "$alt"; then p="$alt"; break; fi
      done
      if [[ -n "$p" ]]; then JA_PRESENTES+=("$p"); continue; fi
      for alt in "${alternativas[@]}"; do
        if pacote_disponivel "$alt"; then p="$alt"; break; fi
      done
      if [[ -n "$p" ]]; then
        PARA_INSTALAR+=("$p"); novos=$((novos + 1))
      else
        PULADOS+=("${entrada//\// ou }")
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

# --- 5. Swap --------------------------------------------------------------------
# Regex de uma linha ativa de swap no fstab: <origem> <ponto> swap ...
readonly RE_SWAP_FSTAB='^[[:space:]]*[^#[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)'

desativar_swap() {
  etapa "Desativando o swap (evita que dados de evidência vão parar no disco)"
  if (( ! DESATIVAR_SWAP )); then
    info "Pulado (--manter-swap)"; RESUMO_SWAP="mantido (--manter-swap)"; return 0
  fi

  local ram_mb ativos unidade
  ram_mb="$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
  if (( ram_mb < 3800 )); then
    aviso "A VM tem ${ram_mb} MB de RAM. Sem swap, ferramentas pesadas (Autopsy, Volatility) podem ser encerradas por falta de memória — recomendado 4 GB ou mais."
  fi

  # 1. Desliga o que está ativo agora (partição, arquivo ou zram).
  ativos="$(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "${ativos// /}" ]]; then
    info "Swap ativo: $ativos"
    executar swapoff -a
  else
    ok "Nenhum swap ativo no momento"
  fi

  # 2. Impede que volte no boot: comenta as linhas de swap do fstab (com backup).
  if grep -qE "$RE_SWAP_FSTAB" "$FSTAB" 2>/dev/null; then
    local backup="$FSTAB.pedro-forense-$CARIMBO.bak"
    executar cp -a "$FSTAB" "$backup"
    executar sed -i -E "s/($RE_SWAP_FSTAB.*)/# [pedro-setup-forense] \\1/" "$FSTAB"
    (( DRY_RUN )) || ok "Linhas de swap comentadas em $FSTAB (backup: $backup)"
  else
    ok "$FSTAB sem entradas de swap ativas"
  fi

  # 3. Bloqueia ativações automáticas do systemd (partição GPT de swap, zram etc.).
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    executar systemctl mask swap.target
    for unidade in zramswap.service dphys-swapfile.service; do
      if systemctl cat "$unidade" >/dev/null 2>&1; then
        executar systemctl disable --now "$unidade" || true
        executar systemctl mask "$unidade"
      fi
    done
    (( DRY_RUN )) || ok "swap.target mascarado no systemd (nenhuma swap é ativada no boot)"
  fi

  # 4. Confere.
  if (( DRY_RUN )); then RESUMO_SWAP="seria desativado"; return 0; fi
  ativos="$(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -z "${ativos// /}" ]]; then
    ok "Swap desativado (swapon --show vazio)"; RESUMO_SWAP="desativado"
  else
    erro "Ainda há swap ativo: $ativos"; FALHAS+=("swap"); RESUMO_SWAP="AINDA ATIVO: $ativos"
  fi
}

# --- 6. Proteção de evidências ----------------------------------------------------
# Disco (ou discos, com LVM/RAID) onde está a raiz do sistema, com o barramento.
transporte_da_raiz() {
  local origem
  origem="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -b "$origem" ]] || { echo "desconhecido"; return 0; }
  lsblk -snro TRAN "$origem" 2>/dev/null | grep -v '^$' | sort -u | tr '\n' ' ' || true
}

configurar_protecoes() {
  etapa "Protegendo evidências (sem montagem automática e somente leitura)"

  # 6.1 Sem montagem automática.
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

  # 6.2 Discos USB entram em somente leitura no kernel (blockdev --setro) assim que
  #     aparecem — antes de qualquer montagem. Não aplica se o próprio sistema roda
  #     de um disco USB (ex.: Kali live/persistente em pendrive), senão travaria a raiz.
  local transporte blockdev_bin
  transporte="$(transporte_da_raiz)"
  blockdev_bin="$(command -v blockdev || echo /usr/sbin/blockdev)"
  if [[ "$transporte" == *usb* || "$transporte" == "desconhecido" ]]; then
    aviso "A raiz do sistema está em disco USB ou não foi identificada ($transporte): regra de USB somente leitura NÃO criada. Use 'sudo pf-bloquear /dev/sdX' em cada evidência."
  elif (( DRY_RUN )); then
    info "[dry-run] criaria $REGRA_UDEV_RO"
  else
    {
      echo "# pedro-setup-forense: discos USB conectados ficam em SOMENTE LEITURA no kernel"
      echo "# (blockdev --setro no disco e em cada partição), antes de qualquer montagem."
      echo "# Para gravar num pendrive seu (ex.: levar o relatório): sudo blockdev --setrw /dev/sdX /dev/sdX1"
      echo "# Para desfazer: sudo rm este arquivo && sudo udevadm control --reload-rules"
      printf 'ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="%s --setro $devnode"\n' "$blockdev_bin"
    } >"$REGRA_UDEV_RO"
    ok "Regra udev criada: $REGRA_UDEV_RO (USB em somente leitura)"
  fi

  # 6.3 Montagens feitas pelo udisks (gerenciador de arquivos, udisksctl) saem em
  #     somente leitura, sem executáveis; ext3/ext4 com noload (sem replay do journal).
  if (( DRY_RUN )); then
    info "[dry-run] criaria $UDISKS_CONF"
  else
    mkdir -p "${UDISKS_CONF%/*}"
    if [[ -f "$UDISKS_CONF" ]] && ! grep -q 'pedro-setup-forense' "$UDISKS_CONF"; then
      cp -a "$UDISKS_CONF" "$UDISKS_CONF.pedro-forense-$CARIMBO.bak"
      info "Backup do $UDISKS_CONF existente: $UDISKS_CONF.pedro-forense-$CARIMBO.bak"
    fi
    cat >"$UDISKS_CONF" <<'EOF'
# pedro-setup-forense: montagens feitas pelo udisks (gerenciador de arquivos,
# udisksctl) saem em SOMENTE LEITURA, sem executáveis nem dispositivos.
# ext3/ext4 com noload: não reproduz o journal (que gravaria na mídia).
# Montagens pelo comando 'mount' não passam por aqui: use 'sudo pf-montar'.
# Para desfazer: sudo rm este arquivo (vale na próxima montagem)
[defaults]
defaults=ro,nosuid,nodev,noexec
ext3_defaults=errors=remount-ro,noload
ext4_defaults=errors=remount-ro,noload
EOF
    ok "udisks: montagens em somente leitura por padrão ($UDISKS_CONF)"
  fi

  if command -v udevadm >/dev/null; then
    executar udevadm control --reload-rules || aviso "Não deu para recarregar o udev agora; as regras valem após reiniciar"
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

# --- 7. Utilitários pf-* e pasta ~/forense ----------------------------------------
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

  instalar_utilitario pf-montar <<'UTIL'
#!/usr/bin/env bash
# pf-montar — monta uma evidência em SOMENTE LEITURA, com opções forenses
#   - bloqueia escrita no disco inteiro antes (pf-bloquear)
#   - ro,noexec,nodev,nosuid + sem replay de journal (ext3/4: noload, xfs: norecovery)
#   - aceita partição (/dev/sdX1) ou arquivo de imagem (.dd/.raw), via loop somente leitura
set -euo pipefail
if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Uso: sudo -E pf-montar <partição /dev/sdX1 | imagem.dd> [ponto de montagem]"
  echo "Padrão do ponto de montagem: /mnt/evidencia/<nome>"
  exit 1
fi
if [[ $EUID -ne 0 ]]; then echo "Precisa de root: sudo -E pf-montar $*" >&2; exit 1; fi
origem="$1"

if [[ -f "$origem" ]]; then
  # Imagem: loop somente leitura (-r), com leitura da tabela de partições (-P).
  dev="$(losetup -r -f -P --show "$origem")"
  echo "Imagem associada a $dev (somente leitura)"
  mapfile -t particoes < <(lsblk -lnpo NAME,TYPE "$dev" | awk '$2 == "part" {print $1}')
  if (( ${#particoes[@]} )); then
    echo "A imagem tem partições — monte a desejada:" >&2
    lsblk -po NAME,SIZE,FSTYPE,LABEL "$dev" >&2
    echo "Ex.: sudo -E pf-montar ${particoes[0]}" >&2
    exit 3
  fi
elif [[ -b "$origem" ]]; then
  dev="$origem"
else
  echo "Origem não é partição nem arquivo: $origem" >&2; exit 1
fi

# Bloqueia o disco inteiro (e todas as partições), não só a partição montada.
pai="$(lsblk -dno PKNAME "$dev" 2>/dev/null || true)"
disco="$dev"; if [[ -n "$pai" ]]; then disco="/dev/$pai"; fi
pf-bloquear "$disco" >/dev/null
echo "Escrita bloqueada em $disco (e em todas as partições)"

if findmnt -rno TARGET -S "$dev" >/dev/null 2>&1; then
  echo "ATENÇÃO: $dev já está montado em $(findmnt -rno TARGET -S "$dev")" >&2; exit 1
fi

tipo="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
opcoes="ro,noexec,nodev,nosuid"
case "$tipo" in
  ext3|ext4) opcoes+=",noload" ;;
  xfs)       opcoes+=",norecovery" ;;
  btrfs)     opcoes+=",rescue=nologreplay" ;;
  "")        echo "Sistema de arquivos não identificado em $dev" >&2; exit 1 ;;
esac

ponto="${2:-/mnt/evidencia/$(basename "$dev")}"
mkdir -p "$ponto"
mount -o "$opcoes" "$dev" "$ponto"

if findmnt -rno OPTIONS "$ponto" | tr ',' '\n' | grep -qx ro; then
  echo "Montado em $ponto ($tipo, $opcoes) — somente leitura: SIM"
else
  echo "Montado em $ponto, mas NÃO está somente leitura — desmontando." >&2
  umount "$ponto"; exit 2
fi
echo "Para desmontar: sudo umount $ponto"
if [[ "$disco" == /dev/loop* ]]; then echo "Depois, libere a imagem: sudo losetup -d $disco"; fi

if [[ -n "${PF_CASO:-}" ]]; then
  printf '%s | %s | Montagem somente leitura de %s em %s (%s, %s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-$(id -un)}" "$origem" "$ponto" "$tipo" "$opcoes" \
    >>"$PF_CASO/00_admin/log-de-acoes.log"
fi
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

# --- 8. Integridade do sistema ----------------------------------------------------
# Escreve uma seção do relatório com a saída (ou "nada encontrado").
secao_relatorio() {
  local titulo="$1" arquivo="$2"
  {
    printf '\n## %s\n\n' "$titulo"
    if [[ -s "$arquivo" ]]; then
      echo '```'; cat "$arquivo"; echo '```'
    else
      echo "Nada encontrado."
    fi
  } >>"$RELATORIO_INTEGRIDADE"
}

# Guia de leitura dos alertas: o que costuma aparecer numa estação Kali/Debian
# recém-configurada e como confirmar. Os alertas NÃO são silenciados — numa
# estação forense é melhor ver e justificar do que esconder.
notas_falsos_positivos() {
  cat <<'EOF'

## Como ler os alertas — falsos positivos comuns no Kali/Debian

Os itens abaixo aparecem com frequência numa estação recém-configurada e,
em geral, não indicam comprometimento. Confirme antes de descartar.

| Ferramenta | Alerta | Por que costuma ser normal | Como confirmar |
|---|---|---|---|
| rkhunter | `lwp-request` substituído por script | É um script Perl desde sempre (pacote libwww-perl) | `dpkg -S /usr/bin/lwp-request` e `dpkg --verify libwww-perl` |
| rkhunter | Memória compartilhada grande (xfdesktop, thunar, Xorg…) | Área de trabalho usa memória compartilhada para imagens | Processo pertence ao seu usuário e ao ambiente gráfico |
| rkhunter | Usuário/grupo `clamav` adicionado | Criado pela instalação do ClamAV neste setup | `dpkg -l clamav` |
| rkhunter | `PermitRootLogin` não definido | Recomendação de configuração do SSH, não infecção | `systemctl is-active ssh` (no Kali vem desligado) |
| rkhunter | `/dev/shm/sem.haveged_sem` | Semáforo do serviço de entropia `haveged` | `systemctl status haveged` |
| rkhunter | `/etc/.java`, `/etc/.updated` | Preferências do Java; marcador de atualização do systemd | `cat /etc/.updated` mostra a data da última atualização |
| chkrootkit | Arquivos ocultos com `[From Debian package: …]` | Arquivos legítimos de pacotes (`.gitkeep`, `.document`…) | Já conferidos pelo `dpkg --verify` acima |
| chkrootkit | `PACKET SNIFFER(/usr/sbin/NetworkManager…)` | O NetworkManager abre socket de rede bruto para o DHCP | `ip link show` não deve mostrar `PROMISC` |
| dpkg | Arquivos `*.original` ausentes em `/etc` | Backups criados e removidos pelos pacotes de personalização do Kali | `dpkg -S <arquivo>` |

Atenção de verdade: arquivo de **programa** com hash diferente no `dpkg --verify`,
`INFECTED` no chkrootkit, interface em modo `PROMISC` sem você ter ativado, ou
alerta do rkhunter sobre rootkit conhecido.
EOF
}

validar_integridade() {
  etapa "Validando a integridade do sistema"
  if (( ! VERIFICAR )); then info "Pulado (--sem-verificacao)"; return 0; fi
  RELATORIO_INTEGRIDADE="$DIR_FORENSE/inventario/integridade-sistema-$CARIMBO.md"
  if (( DRY_RUN )); then
    executar dpkg --verify
    executar rkhunter --propupd
    executar rkhunter --check --skip-keypress --report-warnings-only
    executar chkrootkit -q
    info "[dry-run] geraria $RELATORIO_INTEGRIDADE"
    return 0
  fi

  local tmp n_pacote n_conf n_ausentes n_rk n_chk n_chk_pac
  tmp="$(mktemp -d)"

  # 8.1 Arquivos de todos os pacotes instalados contra os hashes do dpkg.
  #     Linha "??5?????? c /etc/x" = arquivo de configuração alterado (esperado após ajustes);
  #     sem o "c" = binário/biblioteca diferente do que o pacote instalou (suspeito).
  info "dpkg --verify: conferindo os arquivos de todos os pacotes (pode levar alguns minutos)..."
  LC_ALL=C dpkg --verify >"$tmp/dpkg-todos" 2>&1 || true
  #     "missing" = arquivo do pacote que não existe mais (comum em docs/manuais excluídos).
  awk '/^dpkg:/ {next} $2 != "c" && $1 != "missing"' "$tmp/dpkg-todos" >"$tmp/dpkg-pacote"
  awk '/^dpkg:/ {next} $2 == "c"' "$tmp/dpkg-todos" >"$tmp/dpkg-conf"
  awk '/^dpkg:/ {next} $2 != "c" && $1 == "missing"' "$tmp/dpkg-todos" >"$tmp/dpkg-ausentes"
  grep '^dpkg:' "$tmp/dpkg-todos" >"$tmp/dpkg-avisos" || true
  n_pacote="$(grep -c . "$tmp/dpkg-pacote" || true)"
  n_conf="$(grep -c . "$tmp/dpkg-conf" || true)"
  n_ausentes="$(grep -c . "$tmp/dpkg-ausentes" || true)"
  if (( n_pacote == 0 )); then
    ok "dpkg: todos os arquivos de programas existentes conferem com os pacotes"
  else
    aviso "dpkg: $n_pacote arquivo(s) de programas com hash diferente do pacote original — veja o relatório"
  fi
  info "dpkg: $n_conf arquivo(s) de configuração alterados (normal após ajustes do sistema)"
  if (( n_ausentes )); then info "dpkg: $n_ausentes arquivo(s) de pacotes ausentes (geralmente documentação removida)"; fi
  RESUMO_INTEGRIDADE+=("dpkg --verify: $n_pacote arquivo(s) de programas alterados, $n_conf de configuração alterados, $n_ausentes ausentes")

  # 8.2 rkhunter: com o sistema já conferido acima, registra a base de propriedades
  #     dos arquivos (--propupd) e procura rootkits.
  if command -v rkhunter >/dev/null; then
    info "rkhunter: registrando a base dos arquivos do sistema e procurando rootkits..."
    rkhunter --propupd --nocolors >>"$LOG" 2>&1 || true
    rkhunter --check --skip-keypress --report-warnings-only --nocolors >"$tmp/rkhunter" 2>&1 || true
    # Debian/Kali trazem WEB_CMD="/bin/false", que o rkhunter rejeita; corrige e repete.
    if grep -q 'Invalid WEB_CMD' "$tmp/rkhunter" && grep -q '^WEB_CMD=' /etc/rkhunter.conf 2>/dev/null; then
      cp -a /etc/rkhunter.conf "/etc/rkhunter.conf.pedro-forense-$CARIMBO.bak"
      sed -i 's|^WEB_CMD=.*|WEB_CMD=""|' /etc/rkhunter.conf
      info "rkhunter: WEB_CMD inválido corrigido em /etc/rkhunter.conf (backup criado)"
      rkhunter --propupd --nocolors >>"$LOG" 2>&1 || true
      rkhunter --check --skip-keypress --report-warnings-only --nocolors >"$tmp/rkhunter" 2>&1 || true
    fi
    n_rk="$(grep -c 'Warning:' "$tmp/rkhunter" || true)"
    if (( n_rk == 0 )); then ok "rkhunter: nenhum alerta"; else aviso "rkhunter: $n_rk alerta(s) — revise no relatório (há falsos positivos comuns)"; fi
    RESUMO_INTEGRIDADE+=("rkhunter: $n_rk alerta(s)")
  else
    aviso "rkhunter não instalado — verificação pulada"; : >"$tmp/rkhunter"
    RESUMO_INTEGRIDADE+=("rkhunter: não executado")
  fi

  # 8.3 chkrootkit em modo silencioso: só imprime o que for suspeito.
  if command -v chkrootkit >/dev/null; then
    info "chkrootkit: procurando rootkits..."
    chkrootkit -q >"$tmp/chkrootkit-bruto" 2>&1 || true
    # Arquivos ocultos que o próprio chkrootkit identifica como de pacote Debian
    # ("[From Debian package: x]") já foram conferidos pelo dpkg --verify: vão para
    # uma seção informativa. O resto segue como item a revisar; um cabeçalho
    # ("...found:") só aparece se houver item depois dele.
    grep -F '[From Debian package' "$tmp/chkrootkit-bruto" >"$tmp/chkrootkit-pacotes" || true
    awk '
      /\[From Debian package/ {next}
      /^[[:space:]]*$/         {next}
      /:[[:space:]]*$/         {cab = $0; next}
      { if (cab != "") { print cab; cab = "" }; print }
    ' "$tmp/chkrootkit-bruto" >"$tmp/chkrootkit"
    n_chk="$(grep -cv ':[[:space:]]*$' "$tmp/chkrootkit" || true)"
    n_chk_pac="$(grep -c . "$tmp/chkrootkit-pacotes" || true)"
    if (( n_chk == 0 )); then ok "chkrootkit: nada suspeito"; else aviso "chkrootkit: $n_chk item(ns) para revisar no relatório"; fi
    if (( n_chk_pac )); then info "chkrootkit: $n_chk_pac arquivo(s) ocultos de pacotes Debian (informativo, já conferidos pelo dpkg)"; fi
    RESUMO_INTEGRIDADE+=("chkrootkit: $n_chk item(ns) para revisar, $n_chk_pac arquivo(s) ocultos de pacotes (informativo)")
  else
    aviso "chkrootkit não instalado — verificação pulada"
    : >"$tmp/chkrootkit"; : >"$tmp/chkrootkit-pacotes"
    RESUMO_INTEGRIDADE+=("chkrootkit: não executado")
  fi

  {
    echo "# Integridade do sistema — estação forense"
    echo
    echo "- Gerado em (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Host: $(hostname)"
    echo "- Sistema: $DISTRO_NOME | kernel $(uname -r)"
    echo "- Swap: ${RESUMO_SWAP:-não avaliado}"
    echo
    echo "## Resumo"
    echo
    printf -- '- %s\n' "${RESUMO_INTEGRIDADE[@]}"
    echo
    echo "Legenda do dpkg --verify: o \`5\` na 3ª posição indica hash MD5 diferente do pacote;"
    echo "\`c\` marca arquivo de configuração; \`missing\`, arquivo do pacote que não existe mais."
  } >"$RELATORIO_INTEGRIDADE"
  secao_relatorio "dpkg --verify — arquivos de programas alterados (suspeitos)" "$tmp/dpkg-pacote"
  secao_relatorio "dpkg --verify — arquivos de configuração alterados" "$tmp/dpkg-conf"
  secao_relatorio "dpkg --verify — avisos do dpkg" "$tmp/dpkg-avisos"
  secao_relatorio "dpkg --verify — arquivos de pacotes ausentes" "$tmp/dpkg-ausentes"
  secao_relatorio "rkhunter — alertas" "$tmp/rkhunter"
  secao_relatorio "chkrootkit — itens para revisar" "$tmp/chkrootkit"
  secao_relatorio "chkrootkit — arquivos ocultos de pacotes Debian (informativo)" "$tmp/chkrootkit-pacotes"
  notas_falsos_positivos >>"$RELATORIO_INTEGRIDADE"
  rm -rf "$tmp"
  chown "$USUARIO:$GRUPO_USUARIO" "$RELATORIO_INTEGRIDADE"
  registrar "Relatório de integridade: $RELATORIO_INTEGRIDADE | SHA-256 $(sha256sum "$RELATORIO_INTEGRIDADE" | cut -d' ' -f1)"
  ok "Relatório: $RELATORIO_INTEGRIDADE"
}

# --- 9. Inventário --------------------------------------------------------------
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
    echo "- Swap: ${RESUMO_SWAP:-não avaliado}"
    if [[ -n "$RELATORIO_INTEGRIDADE" && -f "$RELATORIO_INTEGRIDADE" ]]; then
      echo "- Integridade do sistema: \`${RELATORIO_INTEGRIDADE##*/}\` (SHA-256 $(sha256sum "$RELATORIO_INTEGRIDADE" | cut -d' ' -f1))"
    fi
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
  if [[ -n "$RESUMO_SWAP" ]]; then info "Swap: $RESUMO_SWAP"; fi
  local linha
  for linha in "${RESUMO_INTEGRIDADE[@]}"; do info "Integridade — $linha"; done
  if [[ -n "$RELATORIO_INTEGRIDADE" && -f "$RELATORIO_INTEGRIDADE" ]]; then info "Relatório de integridade: $RELATORIO_INTEGRIDADE"; fi
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
  4. Só agora conecte a evidência. Para montar: sudo -E pf-montar /dev/sdX1
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
  desativar_swap
  configurar_protecoes
  instalar_utilitarios
  validar_integridade
  gerar_inventario
  resumo
}

main "$@"
