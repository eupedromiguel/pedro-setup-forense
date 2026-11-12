# Pedro Ataides - Setup Forense

Script que transforma uma VM Linux recém-instalada em uma **estação de Forense Digital** pronta para laboratório: instala as ferramentas, protege as evidências contra alteração acidental, cria utilitários para conduzir um caso do início ao fim e gera um inventário auditável das ferramentas.

> Projeto de portfólio - laboratório de estudos em Segurança da Informação / DFIR.

docs/banner.png

---

## O que o script faz

| Etapa | Descrição |
|---|---|
| 1. Verificação | Confere root, distribuição (Ubuntu/Debian/Kali), se está em VM (VirtualBox) e espaço em disco |
| 2. Repositórios | Habilita o `universe` no Ubuntu, se preciso, e atualiza os índices (espera o lock do apt, comum em VM recém-criada) |
| 3. Ferramentas | Instala em lote; se falhar, tenta pacote a pacote para isolar o problema. Pacotes que não existem na distro são pulados e reportados |
| 4. Python | Instala Volatility 3 e oletools via `pipx`, no usuário normal (não root) |
| 5. Proteção | Desativa a montagem automática de mídias (regra udev + GNOME/XFCE) |
| 6. Utilitários | Cria os comandos `pf-*` e a pasta `~/forense` |
| 7. Inventário | Gera um `.md` com versão, pacote, caminho e SHA-256 de cada ferramenta |

Tudo é registrado com horário UTC em `/var/log/pedro-setup-forense/`. Há modo `--dry-run` para ver o que seria feito sem alterar nada.

## Ferramentas instaladas

| Categoria | Ferramentas |
|---|---|
| Aquisição e imagens | dc3dd, dcfldd, ewf-tools (E01), afflib-tools, qemu-utils |
| Disco e sistemas de arquivos | The Sleuth Kit (mmls, fls, icat…), TestDisk/PhotoRec, libvshadow (Shadow Copies), ntfs-3g |
| Carving e metadados | foremost, scalpel, binwalk, bulk_extractor\*, exiftool, exiv2 |
| Hashes e integridade | hashdeep, ssdeep (fuzzy hashing) |
| Malware e IOCs | YARA, ClamAV, chkrootkit, rkhunter |
| Rede | tshark, tcpdump |
| Artefatos Windows e e-mail | reglookup, RegRipper, pst-utils / pff-tools (PST/OST) |
| Memória e documentos | Volatility 3, oletools (via pipx) |
| Interface gráfica (opcional) | Wireshark, Guymager, Autopsy, GHex |

\* `bulk_extractor` não existe nos repositórios do Ubuntu 24.04 (existe no Kali); o script detecta e pula.

## Utilitários de caso (`pf-*`)

| Comando | Função |
|---|---|
| `pf-novo-caso <ID> [examinador]` | Cria a estrutura do caso com modelo de **cadeia de custódia**, notas e log de ações |
| `pf-nota "texto"` | Registra uma ação no log do caso, com horário UTC e usuário |
| `pf-hash <arquivo...>` | Calcula MD5, SHA-1 e SHA-256 numa única leitura e registra em `hashes.tsv` |
| `sudo pf-bloquear /dev/sdX` | Bloqueio de escrita por software (`blockdev --setro`) no disco e em todas as partições |
| `sudo -E pf-adquirir <origem> [nome.dd]` | Aquisição com dc3dd: bloqueia, copia, calcula e **confere** o SHA-256 da imagem |

Estrutura criada por `pf-novo-caso`:

```
~/forense/casos/CASO-001/
├── 00_admin/        cadeia-de-custodia.md, notas-do-caso.md, log-de-acoes.log, hashes.tsv
├── 01_evidencias/
├── 02_imagens/      imagens .dd + log do dc3dd + .sha256
├── 03_exportados/
├── 04_analise/
└── 05_relatorio/
```

## Como usar

**Requisitos sugeridos da VM (VirtualBox):** Ubuntu 22.04/24.04 ou Kali, 2 vCPUs, 4 GB de RAM, 60 GB de disco, rede em NAT durante a instalação.

```bash
git clone https://github.com/eupedromiguel/pedro-setup-forense
cd pedro-setup-forense
chmod +x pedro-setup-forense.sh

./pedro-setup-forense.sh --dry-run     # simula, sem alterar nada
sudo ./pedro-setup-forense.sh          # instalação completa
sudo ./pedro-setup-forense.sh --sem-gui   # VM sem interface gráfica
```

Depois da instalação: reinicie, tire um snapshot `forense-baseline` e, durante as análises, deixe a rede da VM em **Não conectado** ou **Host-only**.

## Exemplo de fluxo (treino)

```bash
# 1. Cria uma "evidência" de treino: pendrive FAT de 16 MB com um arquivo apagado
dd if=/dev/zero of=pendrive-teste.img bs=1M count=16
mkfs.vfat -n EVIDENCIA pendrive-teste.img
echo "relatorio financeiro" > planilha.txt
echo "senha do wifi: 123"  > segredo.txt
mcopy -i pendrive-teste.img planilha.txt segredo.txt ::/
mdel  -i pendrive-teste.img ::/segredo.txt

# 2. Abre o caso
pf-novo-caso CASO-001 "Pedro"
export PF_CASO=~/forense/casos/CASO-001
pf-nota "Recebido pendrive-teste.img para análise"

# 3. Aquisição com verificação de integridade
pf-adquirir pendrive-teste.img          # arquivo de treino: não precisa de sudo
# sudo -E pf-adquirir /dev/sdb          # disco real: bloqueia escrita antes de copiar
pf-hash "$PF_CASO"/02_imagens/*.dd

# 4. Análise
fls -r "$PF_CASO"/02_imagens/*.dd
#   r/r 4:    planilha.txt
#   r/r * 5:  _egredo.txt    <- apagado (*); no FAT a 1ª letra do nome é sobrescrita
pf-nota "fls: encontrado arquivo apagado segredo.txt (inode 5)"
icat "$PF_CASO"/02_imagens/*.dd 5 > "$PF_CASO/03_exportados/segredo.txt"
```

## Boas práticas forenses aplicadas

- **Preservação da evidência:** sem montagem automática; bloqueio de escrita antes da aquisição.
- **Integridade:** hash da origem calculado durante a cópia e conferido contra a imagem.
- **Cadeia de custódia:** modelo baseado nos arts. 158-A a 158-F do CPP (Lei 13.964/2019) e na ABNT NBR ISO/IEC 27037.
- **Rastreabilidade:** log de ações por caso, sempre em UTC.
- **Validação de ferramentas:** inventário com versão e SHA-256 de cada binário usado na estação.
- **Isolamento:** laboratório em VM, com snapshot de referência e rede isolada durante análises.

## Desfazer

```bash
sudo rm /usr/local/bin/pf-{novo-caso,nota,hash,bloquear,adquirir}
sudo rm /etc/udev/rules.d/99-pedro-forense-sem-automount.rules
sudo udevadm control --reload-rules
```

Ou simplesmente volte ao snapshot anterior da VM.

**Aviso:** uso educacional, em ambiente de laboratório. 
