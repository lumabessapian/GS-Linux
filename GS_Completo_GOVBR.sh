#!/bin/bash
set -e
if [ "$(id -u)" -ne 0 ]; then
  echo "Execute com sudo ou como root."
  exit 1
fi


pausa() { read -r -p "Pressione ENTER para continuar..." _; }
confirma() { local r; read -r -p "$1 [s/N]: " r; [[ "$r" == [sS] ]]; }
instala() { dnf install -y "$@"; }
servico() { systemctl enable --now "$1"; systemctl is-active "$1"; }
backup() { if [ -f "$1" ]; then cp -a "$1" "$1.gs.bak.$(date +%Y%m%d%H%M%S)"; fi; }
firewall_servico() { if systemctl is-active --quiet firewalld; then firewall-cmd --permanent --add-service="$1"; firewall-cmd --reload; fi; }
validar_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local a; IFS=. read -ra a <<< "$1"; for p in "${a[@]}"; do (( 10#$p <= 255 )) || return 1; done; }
validar_dominio() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$1" == *.* ]] && [[ "$1" != *..* ]]; }


aula_rede() {
  echo "Interfaces e rede"
  ip -4 addr
  ip route
  cat /etc/resolv.conf
  nmcli device status || true
  if confirma "Mostrar teste de conectividade com a internet?"; then ping -c 2 1.1.1.1 || true; fi
  if confirma "Consultar o DNS atual?"; then read -r -p "Nome (ex: www.google.com): " nome; getent ahostsv4 "$nome" || true; fi
  echo "Para alterar IP fixo use nmcli/nmtui com os dados da rede entregues pelo professor."
}


aula_pacotes() {
  echo "Pacotes no AlmaLinux"
  rpm -q bash
  dnf repolist
  dnf list installed | head -n 30 || true
  if confirma "Pesquisar pacote?"; then read -r -p "Nome do pacote: " nome; dnf search "$nome" || true; fi
  echo "Para instalar um pacote: sudo dnf install nome-do-pacote"
}


aula_vi() {
  echo "Editor VI"
  echo "i: inserir | a: inserir a direita | o: nova linha | ESC: modo comando"
  echo "yy: copiar linha | p: colar | dd: remover linha | u: desfazer | Ctrl+r: refazer"
  echo "j/k/h/l: movimentar | /texto: buscar | :w: salvar | :wq: salvar e sair | :q!: sair sem salvar"
  if confirma "Abrir um arquivo de treino com o vi?"; then
    printf 'Linux\npasswd\nDNS\nApache\n' > /tmp/gs_treino_vi.txt
    vi /tmp/gs_treino_vi.txt
  fi
}


aula_dns() {
  echo "DNS primario - BIND"
  read -r -p "Dominio (ex: gs.test): " dominio
  read -r -p "IP do servidor DNS: " ip
  validar_dominio "$dominio" || { echo "Dominio invalido"; return 1; }
  validar_ipv4 "$ip" || { echo "IP invalido"; return 1; }
  read -r -p "Nome do host extra (ex: app; ENTER para pular): " extra
  if [ -n "$extra" ]; then
    [[ "$extra" =~ ^[a-zA-Z0-9-]+$ ]] || { echo "Host invalido"; return 1; }
    read -r -p "IP do registro $extra: " extraip
    validar_ipv4 "$extraip" || { echo "IP invalido"; return 1; }
  fi
  echo "Dominio: $dominio | IP: $ip"
  confirma "Instalar e configurar servidor DNS primario?" || return 0
  instala bind bind-utils
  mkdir -p /etc/named/gs-zonas
  backup /etc/named.conf
  sed -i -E 's/^[[:space:]]*listen-on port 53[[:space:]]*\{[^}]*\};/        listen-on port 53 { any; };/' /etc/named.conf
  sed -i -E 's/^[[:space:]]*allow-query[[:space:]]*\{[^}]*\};/        allow-query { any; };/' /etc/named.conf
  if ! grep -Fq 'include "/etc/named/gs-zonas.conf";' /etc/named.conf; then
    printf '\ninclude "/etc/named/gs-zonas.conf";\n' >> /etc/named.conf
  fi
  if ! grep -Fq "zone \"$dominio\"" /etc/named/gs-zonas.conf 2>/dev/null; then
    printf '\nzone "%s" IN { type master; file "gs-%s.zone"; allow-transfer { none; }; };\n' "$dominio" "$dominio" >> /etc/named/gs-zonas.conf
  fi
  local serial extras
  serial="$(date +%Y%m%d)01"
  extras=""
  if [ -n "$extra" ]; then extras="$extra IN A $extraip"; fi
  cat > "/var/named/gs-$dominio.zone" <<EOF
\$TTL 300
@ IN SOA ns1.$dominio. admin.$dominio. (
  $serial
  28800
  14400
  86400
  600
)
@ IN NS ns1.$dominio.
@ IN A $ip
ns1 IN A $ip
www IN A $ip
$extras
EOF
  chown root:named "/var/named/gs-$dominio.zone"
  chmod 640 "/var/named/gs-$dominio.zone"
  restorecon -v "/var/named/gs-$dominio.zone" || true
  named-checkconf -z
  servico named
  firewall_servico dns
  dig @127.0.0.1 "www.$dominio" +short
  echo "Zona criada. Para zona reversa use o script DNS primario da atividade com o prefixo da sua rede."
}


aula_dns_reversa() {
  echo "Zona reversa para rede /24"
  read -r -p "Rede /24 (ex: 192.168.56): " rede
  [[ "$rede" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo "Rede invalida"; return 1; }
  local a b c rev ip dominio ultimo
  IFS=. read -r a b c <<< "$rede"
  (( a<=255 && b<=255 && c<=255 )) || return 1
  rev="$c.$b.$a.in-addr.arpa"
  read -r -p "Dominio ja criado (ex: gs.test): " dominio
  validar_dominio "$dominio" || return 1
  read -r -p "IP do ns1 nesta rede: " ip
  validar_ipv4 "$ip" || return 1
  [[ "$ip" == "$rede".* ]] || { echo "IP nao esta na rede informada"; return 1; }
  ultimo="${ip##*.}"
  confirma "Adicionar zona reversa $rev?" || return 0
  instala bind bind-utils
  if ! grep -Fq 'include "/etc/named/gs-zonas.conf";' /etc/named.conf; then printf '\ninclude "/etc/named/gs-zonas.conf";\n' >> /etc/named.conf; fi
  touch /etc/named/gs-zonas.conf
  if ! grep -Fq "zone \"$rev\"" /etc/named/gs-zonas.conf; then
    printf 'zone "%s" IN { type master; file "gs-%s.zone"; allow-transfer { none; }; };\n' "$rev" "$rev" >> /etc/named/gs-zonas.conf
  fi
  cat > "/var/named/gs-$rev.zone" <<EOF
\$TTL 300
@ IN SOA ns1.$dominio. admin.$dominio. (
  $(date +%Y%m%d)01
  28800
  14400
  86400
  600
)
@ IN NS ns1.$dominio.
$ultimo IN PTR ns1.$dominio.
EOF
  chown root:named "/var/named/gs-$rev.zone"
  chmod 640 "/var/named/gs-$rev.zone"
  restorecon -v "/var/named/gs-$rev.zone" || true
  named-checkconf -z
  systemctl restart named
  dig @127.0.0.1 -x "$ip" +short
}


aula_dns_secundario() {
  echo "DNS secundario - precisa de 2 VMs diferentes"
  read -r -p "Dominio do master: " dominio
  read -r -p "IPv4 do master: " master
  validar_dominio "$dominio" && validar_ipv4 "$master" || { echo "Dados invalidos"; return 1; }
  confirma "Esta e a VM SECUNDARIA (nao execute na master)?" || return 0
  instala bind bind-utils
  backup /etc/named.conf
  sed -i -E 's/^[[:space:]]*listen-on port 53[[:space:]]*\{[^}]*\};/        listen-on port 53 { any; };/' /etc/named.conf
  sed -i -E 's/^[[:space:]]*allow-query[[:space:]]*\{[^}]*\};/        allow-query { any; };/' /etc/named.conf
  if ! grep -Fq 'include "/etc/named/gs-zonas.conf";' /etc/named.conf; then printf '\ninclude "/etc/named/gs-zonas.conf";\n' >> /etc/named.conf; fi
  touch /etc/named/gs-zonas.conf
  if ! grep -Fq "zone \"$dominio\"" /etc/named/gs-zonas.conf; then
    printf 'zone "%s" IN { type slave; masters { %s; }; file "slaves/gs-%s.zone"; };\n' "$dominio" "$master" "$dominio" >> /etc/named/gs-zonas.conf
  else
    echo "Zona ja existe: conferir antes de substituir."
  fi
  named-checkconf
  servico named
  firewall_servico dns
  echo "No MASTER autorize allow-transfer apenas para o IP desta VM; sem isso a transferencia nao ocorre."
  ls -la /var/named/slaves/
  journalctl -u named -n 15 --no-pager || true
}


aula_apache() {
  echo "Apache e pagina HTML"
  read -r -p "URL publica do HTML [https://www.gov.br/pt-br/pagina-inicial]: " url
  url="${url:-https://www.gov.br/pt-br/pagina-inicial}"
  [[ "$url" == https://* ]] || { echo "Use uma URL https://"; return 1; }
  confirma "Instalar Apache e trocar a pagina inicial pela pagina baixada?" || return 0
  instala httpd curl
  backup /etc/httpd/conf/httpd.conf
  if grep -qE '^Listen[[:space:]]+[0-9]+' /etc/httpd/conf/httpd.conf; then
    sed -i -E 's/^Listen[[:space:]]+[0-9]+/Listen 80/' /etc/httpd/conf/httpd.conf
  fi
  printf 'ServerTokens Prod\nServerSignature Off\n' > /etc/httpd/conf.d/gs-seguranca.conf
  curl -fL --max-time 90 "$url" -o /tmp/gs-site.html || { echo "Falha no download; site antigo mantido."; return 1; }
  [ -s /tmp/gs-site.html ] || { echo "HTML vazio."; return 1; }
  cp -a /var/www/html/index.html "/var/www/html/index.html.gs.bak.$(date +%s)" 2>/dev/null || true
  cp /tmp/gs-site.html /var/www/html/index.html
  sed -i -E '0,/<head[^>]*>/s#<head([^>]*)>#<head\1><base href="'"$url"'">#I' /var/www/html/index.html
  if grep -qi '<body' /var/www/html/index.html; then
    sed -i -E '0,/<body[^>]*>/s#<body([^>]*)>#<body\1><div style="background:#ffefb1;color:#111;padding:12px;text-align:center;font-family:Arial">COPIA DE LABORATORIO - NAO E UM PORTAL OFICIAL. NAO INFORME DADOS PESSOAIS.</div>#I' /var/www/html/index.html
  fi
  chmod 644 /var/www/html/index.html
  restorecon -RF /var/www/html || true
  httpd -t
  servico httpd
  firewall_servico http
  curl -I --max-time 10 http://127.0.0.1 || true
  echo "A copia HTML pode precisar de arquivos externos."
}


aula_ftp() {
  echo "Servidor FTP VSFTPD"
  confirma "Instalar e iniciar servidor FTP de laboratorio? FTP nao criptografa dados." || return 0
  instala vsftpd
  backup /etc/vsftpd/vsftpd.conf
  sed -i -E 's/^anonymous_enable=.*/anonymous_enable=NO/; s/^local_enable=.*/local_enable=YES/; s/^write_enable=.*/write_enable=YES/' /etc/vsftpd/vsftpd.conf
  servico vsftpd
  firewall_servico ftp
  systemctl status vsftpd --no-pager -l | head -n 12 || true
  echo "Para arquivos privados prefira SFTP (SSH)."
}


aula_ssh() {
  echo "OpenSSH"
  confirma "Instalar/ativar servidor SSH?" || return 0
  instala openssh-server
  servico sshd
  firewall_servico ssh
  ss -tlnp | grep ':22' || true
  journalctl -u sshd -n 10 --no-pager || true
  echo "Exemplo cliente: ssh usuario@IP"
  echo "Exemplo copia: scp arquivo usuario@IP:/home/usuario/"
}


aula_proxy() {
  echo "Proxy SQUID"
  confirma "Instalar e iniciar Squid com configuracao padrao?" || return 0
  instala squid
  squid -k parse
  servico squid
  ss -tlnp | grep ':3128' || true
  echo "Regras ACL, cache e proxy reverso dependem do cenario da atividade."
  echo "Nao foi aberto acesso externo irrestrito ao proxy."
}


aula_dhcp() {
  echo "DHCP - somente rede isolada de laboratorio"
  read -r -p "Interface da rede isolada (ex: enp0s8): " iface
  [[ "$iface" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Interface invalida"; return 1; }
  ip link show "$iface" >/dev/null || { echo "Interface inexistente"; return 1; }
  read -r -p "Rede (ex: 192.168.56.0): " rede
  read -r -p "Mascara (ex: 255.255.255.0): " mascara
  read -r -p "IP inicial para clientes: " inicio
  read -r -p "IP final para clientes: " fim
  read -r -p "Gateway: " gateway
  read -r -p "DNS oferecido aos clientes: " dns
  for item in "$rede" "$mascara" "$inicio" "$fim" "$gateway" "$dns"; do validar_ipv4 "$item" || { echo "IPv4 invalido: $item"; return 1; }; done
  echo "ATENCAO: o DHCP pode interferir em outras VMs ou na rede da faculdade."
  confirma "Confirma que essa interface e uma rede isolada e autorizada?" || return 0
  instala dhcp-server
  backup /etc/dhcp/dhcpd.conf
  cat > /etc/dhcp/dhcpd.conf <<EOF
option domain-name-servers $dns;
default-lease-time 600;
max-lease-time 7200;
authoritative;
subnet $rede netmask $mascara {
  range $inicio $fim;
  option routers $gateway;
  option subnet-mask $mascara;
}
EOF
  dhcpd -t -cf /etc/dhcp/dhcpd.conf
  printf 'DHCPDARGS="%s"\n' "$iface" > /etc/sysconfig/dhcpd
  echo "Arquivo criado e verificado. O DHCP NAO foi iniciado automaticamente."
  echo "Se a rede estiver isolada e aprovada: systemctl enable --now dhcpd"
  echo "Verifique concessoes: cat /var/lib/dhcpd/dhcpd.leases"
}


aula_samba() {
  echo "Samba"
  echo "Os slides trazem Samba AD-DC; ele exige dominio, IP fixo, DNS/Kerberos e rede preparados."
  echo "Este exercicio nao faz provisionamento de AD automaticamente."
  confirma "Instalar ferramentas do Samba para estudo e inspecao?" || return 0
  instala samba samba-client samba-common-tools
  testparm -s || true
  systemctl list-unit-files '*smb*' '*nmb*' || true
  echo "Arquivo principal: /etc/samba/smb.conf"
}


aula_backup() {
  echo "Backup, compactacao e cron"
  read -r -p "Pasta que deseja copiar (ex: /etc/httpd): " origem
  [ -d "$origem" ] || { echo "Pasta nao encontrada"; return 1; }
  destino="/root/backup-gs-$(date +%Y%m%d-%H%M%S).tar.gz"
  confirma "Criar arquivo $destino?" || return 0
  tar -czf "$destino" -C / "${origem#/}"
  ls -lh "$destino"
  tar -tzf "$destino" | head -n 10 || true
  echo "Agendamento atual do root:"
  crontab -l 2>/dev/null || true
  echo "Para editar agendamentos: crontab -e"
}


aula_mysql() {
  echo "Banco de dados relacional"
  echo "Material da aula: MySQL e SQL. AlmaLinux pode usar pacotes MariaDB em vez de MySQL."
  if ! confirma "Instalar o servidor MySQL quando disponivel?"; then return 0; fi
  if dnf list --available mysql-server >/dev/null 2>&1 || rpm -q mysql-server >/dev/null 2>&1; then
    instala mysql-server
    servico mysqld
    systemctl status mysqld --no-pager -l | head -n 15 || true
  else
    echo "mysql-server nao esta nos repositorios atuais. Nenhuma alternativa foi instalada automaticamente."
    echo "Verifique com o professor se e permitido usar MariaDB."
  fi
  echo "Exemplos SQL: CREATE TABLE, INSERT INTO, SELECT, UPDATE, DELETE."
}

aula_usuarios() {
  local opcao_usuario usuario grupo caminho dono permissao
  while true; do
    echo ""
    echo "Usuarios e grupos"
    echo "1) Criar usuario"
    echo "2) Criar grupo"
    echo "3) Adicionar usuario a grupo"
    echo "4) Alterar senha"
    echo "5) Consultar usuario e grupos"
    echo "6) Alterar dono de arquivo ou pasta"
    echo "7) Alterar permissao de arquivo ou pasta"
    echo "8) Bloquear usuario"
    echo "9) Desbloquear usuario"
    echo "0) Voltar"
    read -r -p "Opcao: " opcao_usuario
    case "$opcao_usuario" in
      1)
        read -r -p "Nome do novo usuario: " usuario
        if [[ ! "$usuario" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
          echo "Nome invalido."
        elif id "$usuario" >/dev/null 2>&1; then
          echo "Usuario ja existe."
        elif confirma "Criar usuario $usuario com pasta pessoal?"; then
          if useradd -m "$usuario"; then
            echo "Defina a senha do usuario:"
            passwd "$usuario" || echo "Senha nao alterada."
            id "$usuario"
          fi
        fi
        ;;
      2)
        read -r -p "Nome do novo grupo: " grupo
        if [[ ! "$grupo" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
          echo "Nome invalido."
        elif getent group "$grupo" >/dev/null; then
          echo "Grupo ja existe."
        elif confirma "Criar grupo $grupo?"; then
          groupadd "$grupo" && getent group "$grupo"
        fi
        ;;
      3)
        read -r -p "Usuario existente: " usuario
        read -r -p "Grupo existente: " grupo
        if ! id "$usuario" >/dev/null 2>&1 || ! getent group "$grupo" >/dev/null; then
          echo "Usuario ou grupo nao encontrado."
        elif confirma "Adicionar $usuario ao grupo $grupo?"; then
          usermod -aG "$grupo" "$usuario" && id "$usuario"
        fi
        ;;
      4)
        read -r -p "Usuario: " usuario
        if id "$usuario" >/dev/null 2>&1; then
          passwd "$usuario" || echo "Senha nao alterada."
        else
          echo "Usuario nao encontrado."
        fi
        ;;
      5)
        read -r -p "Usuario para consultar: " usuario
        id "$usuario" || echo "Usuario nao encontrado."
        ;;
      6)
        read -r -p "Caminho do arquivo ou pasta: " caminho
        read -r -p "Novo dono (usuario ou usuario:grupo): " dono
        if [ ! -e "$caminho" ]; then
          echo "Caminho nao encontrado."
        elif [[ "$dono" != *:* ]] && ! id "$dono" >/dev/null 2>&1; then
          echo "Usuario nao encontrado."
        elif confirma "Alterar o dono de $caminho para $dono?"; then
          chown "$dono" -- "$caminho" && ls -ld "$caminho"
        fi
        ;;
      7)
        read -r -p "Caminho do arquivo ou pasta: " caminho
        read -r -p "Permissao numerica (ex: 644, 755 ou 700): " permissao
        if [ ! -e "$caminho" ]; then
          echo "Caminho nao encontrado."
        elif [[ ! "$permissao" =~ ^[0-7]{3,4}$ ]]; then
          echo "Permissao invalida."
        elif confirma "Aplicar permissao $permissao em $caminho?"; then
          chmod "$permissao" -- "$caminho" && ls -ld "$caminho"
        fi
        ;;
      8)
        read -r -p "Usuario para bloquear: " usuario
        if [ "$usuario" = root ]; then
          echo "O usuario root nao sera bloqueado por este script."
        elif ! id "$usuario" >/dev/null 2>&1; then
          echo "Usuario nao encontrado."
        elif confirma "Bloquear a senha de $usuario?"; then
          passwd -l "$usuario"
        fi
        ;;
      9)
        read -r -p "Usuario para desbloquear: " usuario
        if ! id "$usuario" >/dev/null 2>&1; then
          echo "Usuario nao encontrado."
        elif confirma "Desbloquear a senha de $usuario?"; then
          passwd -u "$usuario" || echo "Nao foi possivel desbloquear. Defina uma senha com passwd."
        fi
        ;;
      0) return 0 ;;
      *) echo "Opcao invalida" ;;
    esac
  done
}

while true; do
  echo ""
  echo "GS - AlmaLinux: escolha uma atividade"
  echo "1) Rede / cliente DNS"
  echo "2) Pacotes"
  echo "3) Editor VI"
  echo "4) DNS primario"
  echo "5) DNS reverso"
  echo "6) DNS secundario"
  echo "7) Apache / site web"
  echo "8) FTP"
  echo "9) SSH"
  echo "10) Proxy Squid"
  echo "11) DHCP"
  echo "12) Samba"
  echo "13) Backup e cron"
  echo "14) MySQL"
  echo "15) Usuarios e grupos"
  echo "0) Sair"
  read -r -p "Opcao: " opcao
  case "$opcao" in
    1) aula_rede ;;
    2) aula_pacotes ;;
    3) aula_vi ;;
    4) aula_dns ;;
    5) aula_dns_reversa ;;
    6) aula_dns_secundario ;;
    7) aula_apache ;;
    8) aula_ftp ;;
    9) aula_ssh ;;
    10) aula_proxy ;;
    11) aula_dhcp ;;
    12) aula_samba ;;
    13) aula_backup ;;
    14) aula_mysql ;;
    15) aula_usuarios ;;
    0) exit 0 ;;
    *) echo "Opcao invalida" ;;
  esac
done
