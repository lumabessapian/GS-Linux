# GS - Configuracao de DNS e servidor web 
# Script de laboratorio

if [ "$(id -u)" != "0" ]; then
    echo "Execute com sudo ou como root."
    exit 1
fi

echo "===================================="
echo "    GS - DNS e Apache no AlmaLinux"
echo "===================================="
echo "O script vai instalar o BIND e o Apache."
read -r -p "Deseja continuar? (s/n): " RESPOSTA
if [ "$RESPOSTA" != "s" ]; then
    echo "Cancelado."
    exit 0
fi

# Informacoes que podem mudar na prova
read -r -p "Digite o dominio (ex: gs.test): " DOMINIO
read -r -p "Digite o IP da VM (ex: 192.168.56.150): " IP

# Verificacoes simples para nao gravar dados errados nos arquivos
if ! [[ "$DOMINIO" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]]; then
    echo "Dominio invalido."
    exit 1
fi
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "IP invalido."
    exit 1
fi

# Registros extras para a zona DNS
EXTRAS=""
while true; do
    echo
    read -r -p "Adicionar registro DNS? (a/cname/mx/fim): " TIPO
    case "$TIPO" in
        a|A)
            read -r -p "Nome (ex: app): " NOME
            read -r -p "IP do registro: " VALOR
            if [[ "$NOME" =~ ^[a-zA-Z0-9-]+$ && "$VALOR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                EXTRAS+="$NOME IN A $VALOR"$'\n'
            else
                echo "Registro invalido."
            fi
            ;;
        cname|CNAME)
            read -r -p "Apelido (ex: blog): " NOME
            read -r -p "Destino (ex: www): " VALOR
            if [[ "$NOME" =~ ^[a-zA-Z0-9-]+$ && "$VALOR" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                EXTRAS+="$NOME IN CNAME ${VALOR}.${DOMINIO}."$'\n'
            else
                echo "Registro invalido."
            fi
            ;;
        mx|MX)
            read -r -p "Nome do servidor de email (ex: mail): " NOME
            if [[ "$NOME" =~ ^[a-zA-Z0-9-]+$ ]]; then
                EXTRAS+="@ IN MX 10 ${NOME}.${DOMINIO}."$'\n'
                EXTRAS+="$NOME IN A $IP"$'\n'
            else
                echo "Registro invalido."
            fi
            ;;
        fim|FIM|"") break ;;
        *) echo "Digite a, cname, mx ou fim." ;;
    esac
done

echo "Dominio: $DOMINIO"
echo "IP da VM: $IP"
read -r -p "Confirmar as alteracoes? (s/n): " RESPOSTA
if [ "$RESPOSTA" != "s" ]; then exit 0; fi

# 1 - Instalar os programas necessarios
echo "1 - Instalando BIND e Apache..."
dnf install -y bind bind-utils httpd curl firewalld policycoreutils || exit 1

# Guardar as configuracoes anteriores
DATA=$(date +%Y%m%d-%H%M%S)
mkdir -p "/root/backup-gs-$DATA"
cp /etc/named.conf /etc/httpd/conf/httpd.conf "/root/backup-gs-$DATA/"

# 2 - Configurar o DNS
echo "2 - Configurando DNS..."
sed -i 's/listen-on port 53.*;/listen-on port 53 { any; };/' /etc/named.conf
sed -i 's/allow-query.*;/allow-query { any; };/' /etc/named.conf
# Consultas normais permitidas, sem oferecer recursao para a rede
sed -i 's/recursion yes;/recursion no;/' /etc/named.conf

# So adiciona a zona se ela ainda nao existir
if ! grep -q "zone \"$DOMINIO\"" /etc/named.conf; then
cat >> /etc/named.conf <<FIM

zone "$DOMINIO" IN {
    type master;
    file "gs-$DOMINIO.zone";
    allow-transfer { none; };
};
FIM
fi

cat > "/var/named/gs-$DOMINIO.zone" <<FIM
\$TTL 300
@ IN SOA ns1.$DOMINIO. admin.$DOMINIO. (
    $(date +%Y%m%d)01
    3600
    1800
    7200
    600
)
@   IN NS ns1.$DOMINIO.
@   IN A $IP
ns1 IN A $IP
www IN A $IP
$EXTRAS
FIM

chown root:named "/var/named/gs-$DOMINIO.zone"
chmod 640 "/var/named/gs-$DOMINIO.zone"
restorecon "/var/named/gs-$DOMINIO.zone"
named-checkconf -z || exit 1

# 3 - Configurar Apache
echo "3 - Configurando Apache..."
sed -i 's/^Listen 81$/Listen 80/' /etc/httpd/conf/httpd.conf
cat > /etc/httpd/conf.d/gs-security.conf <<FIM
ServerTokens Prod
ServerSignature Off
FIM

# 4 - Baixar o HTML publico do site da FIAP
echo "4 - Baixando o HTML da FIAP..."
URL="https://www.fiap.com.br/"
curl -fL --max-time 60 "$URL" -o /var/www/html/index.html || exit 1
chmod 644 /var/www/html/index.html
restorecon -R /var/www/html
httpd -t || exit 1

# 5 - Iniciar servicos e configurar firewall
echo "5 - Liberando DNS e HTTP no firewall..."
systemctl enable --now firewalld || exit 1
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=dns
firewall-cmd --reload

echo "6 - Iniciando os servicos..."
systemctl enable named httpd
systemctl restart named httpd || exit 1

# 7 - Testes finais
echo "7 - Testando os servicos..."
systemctl is-active named httpd
curl -I http://127.0.0.1
dig @127.0.0.1 "www.$DOMINIO" +short

echo "-----------------------------------"
echo "Fim do script."
echo "Site: http://www.$DOMINIO"
echo "IP da VM: $IP"
echo "Se nao abrir no Windows, confira o DNS ou arquivo hosts."
echo "Lembrete: o HTML da FIAP pode depender de arquivos externos."
