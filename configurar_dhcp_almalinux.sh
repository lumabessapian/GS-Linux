#!/bin/bash
# Configuracao de servidor DHCP IPv4 no AlmaLinux - rede /24
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo 'Execute como root: sudo bash configurar_dhcp_almalinux.sh'
  exit 1
fi

command -v nmcli >/dev/null || { echo 'NetworkManager/nmcli nao encontrado.'; exit 1; }

echo '=== CONFIGURACAO DHCP - ALMALINUX ==='
echo 'Placas de rede:'
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
read -rp 'Nome da placa que atendera os clientes (ex.: enp0s8): ' IFACE
[[ -n "$IFACE" ]] || { echo 'Placa nao informada.'; exit 1; }
[[ $(nmcli -g GENERAL.TYPE device show "$IFACE" 2>/dev/null) == ethernet ]] || { echo 'Interface Ethernet invalida.'; exit 1; }

read -rp 'IP fixo do servidor, rede /24 (ex.: 192.168.50.10): ' SERVER_IP
read -rp 'Primeiro IP da faixa DHCP (ex.: 192.168.50.100): ' START_IP
read -rp 'Ultimo IP da faixa DHCP (ex.: 192.168.50.200): ' END_IP
read -rp 'Gateway dos clientes (Enter se nao existir): ' GATEWAY
read -rp 'DNS dos clientes [8.8.8.8]: ' DNS
DNS=${DNS:-8.8.8.8}

valid_ip() {
  local ip=$1 part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do (( 10#$part <= 255 )) || return 1; done
}
for ip in "$SERVER_IP" "$START_IP" "$END_IP" "$DNS"; do
  valid_ip "$ip" || { echo "IP invalido: $ip"; exit 1; }
done
if [[ -n "$GATEWAY" ]]; then valid_ip "$GATEWAY" || { echo 'Gateway invalido.'; exit 1; }; fi
PREFIX=${SERVER_IP%.*}
for ip in "$START_IP" "$END_IP"; do
  [[ ${ip%.*} == "$PREFIX" ]] || { echo 'A faixa deve estar na mesma rede /24 do servidor.'; exit 1; }
done
if [[ -n "$GATEWAY" && ${GATEWAY%.*} != "$PREFIX" ]]; then
  echo 'Gateway fora da rede /24.'; exit 1
fi
START_LAST=${START_IP##*.}; END_LAST=${END_IP##*.}; SERVER_LAST=${SERVER_IP##*.}
if (( 10#$START_LAST < 1 || 10#$END_LAST > 254 || 10#$START_LAST > 10#$END_LAST )); then
  echo 'Faixa DHCP invalida.'; exit 1
fi
if (( 10#$SERVER_LAST >= 10#$START_LAST && 10#$SERVER_LAST <= 10#$END_LAST )); then
  echo 'O IP do servidor nao pode estar dentro da faixa DHCP.'; exit 1
fi
if [[ -n "$GATEWAY" ]]; then
  GW_LAST=${GATEWAY##*.}
  if (( 10#$GW_LAST >= 10#$START_LAST && 10#$GW_LAST <= 10#$END_LAST )); then
    echo 'O IP do gateway nao pode estar dentro da faixa DHCP.'; exit 1
  fi
fi

printf '\nServidor: %s/24 | Faixa: %s - %s | Gateway: %s | DNS: %s\n' \
  "$SERVER_IP" "$START_IP" "$END_IP" "${GATEWAY:-nenhum}" "$DNS"
echo 'ATENCAO: alterar o IP da interface pode interromper sua conexao.'
echo 'Use somente na rede de laboratorio autorizada, sem outro servidor DHCP.'
read -rp 'Confirma a configuracao? [s/N]: ' CONFIRM
[[ "$CONFIRM" == [sS] ]] || { echo 'Cancelado.'; exit 0; }

# Instalar antes de alterar a rede para preservar acesso a repositorios.
if ! rpm -q dhcp-server >/dev/null 2>&1; then
  dnf install -y dhcp-server
fi

# Selecionar perfil associado a interface; criar se nao existir.
CON=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" | head -n 1)
if [[ -z "$CON" || "$CON" == '--' ]]; then
  CON="dhcp-lan-$IFACE"
  nmcli connection add type ethernet ifname "$IFACE" con-name "$CON"
fi

# A interface do servidor recebe IP estatico, mas sem alterar o gateway padrao.
nmcli connection modify "$CON" ipv4.method manual ipv4.addresses "$SERVER_IP/24" ipv4.never-default yes ipv4.gateway '' ipv4.dns '' connection.autoconnect yes
nmcli connection up "$CON"

# Backup da configuracao anterior, se existir.
[[ ! -f /etc/dhcp/dhcpd.conf ]] || cp -a /etc/dhcp/dhcpd.conf "/etc/dhcp/dhcpd.conf.bak.$(date +%Y%m%d%H%M%S)"
{
  echo 'authoritative;'
  echo 'default-lease-time 600;'
  echo 'max-lease-time 7200;'
  echo "subnet $PREFIX.0 netmask 255.255.255.0 {"
  echo "  range $START_IP $END_IP;"
  echo '  option subnet-mask 255.255.255.0;'
  [[ -z "$GATEWAY" ]] || echo "  option routers $GATEWAY;"
  echo "  option domain-name-servers $DNS;"
  echo '}'
} > /etc/dhcp/dhcpd.conf

# Conferir sintaxe antes de iniciar.
dhcpd -t -cf /etc/dhcp/dhcpd.conf

# Limitar o servico somente a interface selecionada.
mkdir -p /etc/systemd/system/dhcpd.service.d
cat > /etc/systemd/system/dhcpd.service.d/10-interface.conf <<EOC
[Service]
ExecStart=
ExecStart=/usr/sbin/dhcpd -f -cf /etc/dhcp/dhcpd.conf -user dhcpd -group dhcpd --no-pid $IFACE
EOC
systemctl daemon-reload

if systemctl is-active --quiet firewalld; then
  ZONE=$(firewall-cmd --get-zone-of-interface="$IFACE" 2>/dev/null || true)
  [[ -n "$ZONE" && "$ZONE" != 'no zone' ]] || ZONE=$(firewall-cmd --get-default-zone)
  firewall-cmd --permanent --zone="$ZONE" --add-service=dhcp
  firewall-cmd --reload
else
  echo 'Aviso: firewalld nao esta ativo; nenhuma regra foi adicionada.'
fi

systemctl enable --now dhcpd
systemctl restart dhcpd

echo
if systemctl is-active --quiet dhcpd; then
  echo 'SUCESSO: SERVIDOR DHCP ATIVO.'
else
  echo 'ERRO: DHCP nao iniciou. Veja os logs abaixo:'
  journalctl -u dhcpd -n 20 --no-pager
  exit 1
fi
ip -4 addr show dev "$IFACE"
systemctl --no-pager --full status dhcpd
printf '\nClientes devem estar na mesma rede virtual/LAN e usar DHCP automatico.\n'
