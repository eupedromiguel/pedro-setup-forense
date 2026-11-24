# Changelog

Todas as mudanças relevantes deste projeto são registradas aqui.
Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versões seguem [SemVer](https://semver.org/lang/pt-BR/).

## [1.1.0] - 2026-11-24

### Adicionado
- **Etapa "Swap":** desliga o swap (`swapoff -a`), comenta as linhas de swap do `/etc/fstab` (com backup) e mascara o `swap.target` do systemd. Avisa se a VM tiver menos de 4 GB de RAM. Opção `-s`/`--manter-swap` para pular.
- **Somente leitura para discos USB:** regra udev que aplica `blockdev --setro` ao disco e às partições assim que são conectados. Não é criada se a raiz do sistema estiver em disco USB.
- **Montagens do udisks em somente leitura:** `/etc/udisks2/mount_options.conf` com `ro,nosuid,nodev,noexec` (ext3/ext4 com `noload`).
- **Utilitário `pf-montar`:** bloqueia o disco inteiro e monta partição ou imagem `.dd` em somente leitura, sem replay de journal (`noload`, `norecovery`, `rescue=nologreplay`), conferindo o `ro` e registrando no log do caso.
- **Etapa "Integridade":** `dpkg --verify` em todos os pacotes (separando programas alterados, configurações alteradas e arquivos ausentes), base e varredura do `rkhunter` e varredura do `chkrootkit`. Gera `~/forense/inventario/integridade-sistema-<data>.md`. Opção `-i`/`--sem-verificacao` para pular.
- Relatório de integridade com a seção "Como ler os alertas": falsos positivos comuns no Kali/Debian e como confirmar cada um. Os alertas continuam aparecendo (não são silenciados).
- chkrootkit: arquivos ocultos que o próprio chkrootkit identifica como de pacote Debian (`[From Debian package: …]`) ficam numa seção informativa, pois já são conferidos pelo `dpkg --verify`; a contagem mostra só os itens que precisam de revisão.
- Catálogo de pacotes com alternativas (`a/b`): instala a primeira disponível na distro.
- Arquivo `LICENSE` (MIT), `.gitattributes` (scripts sempre com LF) e este `CHANGELOG.md`.

### Alterado
- O script passa de 7 para 9 etapas.
- O inventário de ferramentas registra o estado do swap e o SHA-256 do relatório de integridade.
- O resumo final mostra swap e integridade, e lembra de conectar evidências só depois do setup.
- README: aviso para executar o script antes de conectar evidências à VM, tabela de opções, `pf-montar` e instruções para desfazer as novas configurações.

### Corrigido
- Kali: o pacote `p7zip-full` não existe mais; agora é instalado o `7zip` (`p7zip-full/7zip`).
- `rkhunter` no Debian/Kali: o `WEB_CMD="/bin/false"` padrão, rejeitado pelo próprio rkhunter, é ajustado automaticamente (com backup) quando necessário.

## [1.0.0]

### Adicionado
- Versão inicial: instalação das ferramentas forenses, ferramentas Python via `pipx`, bloqueio da montagem automática de mídias, utilitários `pf-novo-caso`, `pf-nota`, `pf-hash`, `pf-bloquear` e `pf-adquirir`, e inventário de ferramentas com versão e SHA-256.

