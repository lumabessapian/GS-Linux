#!/bin/bash
# =====================================================================
# DEFINITIVO SUPREMO - Servidor DNS (BIND) + Web (Apache) no AlmaLinux
#
# O QUE O SCRIPT FAZ (tudo automatico, sem tarefas manuais depois):
#   1. Pede confirmacao ao usuario antes de alterar o sistema
#   2. Pede o dominio e os registros DNS (A, CNAME, MX) com seus enderecos
#   3. Instala o BIND (DNS) e o Apache (Web) e faz backup das configuracoes
#   4. Cria a zona DNS direta e a zona reversa
#   5. Baixa um template HTML da Internet e publica como pagina padrao
#   6. Libera o firewall, habilita os servicos no boot e testa tudo
#   7. Executa as tarefas extras (funcoes tarefa_extra_1, 2 e 3 abaixo)
#
# USO:
#   bash Definitivo_Supremo.sh                  -> interativo (pergunta tudo, com sugestoes)
#   bash Definitivo_Supremo.sh -y               -> automatico (usa o bloco CONFIGURACAO)
#   bash Definitivo_Supremo.sh -y -d empresa.local -i 192.168.5.69
#   bash Definitivo_Supremo.sh -u https://site.com/template.zip   -> outro template
#   Opcoes: -y automatico | -d dominio | -i ip | -u link do template | -h ajuda
#
# REQUISITOS: AlmaLinux, usuario root (ou sudo), internet na VM.
# LOG: tudo que aparece na tela depois da confirmacao fica em /root/gs.log
# =====================================================================

############################ CONFIGURACAO ############################
# Na prova, se o professor mudar algo, mude AQUI e rode com -y.
DOMINIO="gs.test"
IP=""                      # vazio = detectar sozinho
SITE_MODO="url"            # url = baixa um template da Internet (pedido na GS) | local = pagina gerada pelo script
SITE_URL="https://www.gov.br/pt-br/pagina-inicial/"
BANNER_LAB="s"             # s = poe uma faixa "copia de laboratorio" no topo da pagina baixada
SITE_TITULO="GOV.BR - Laboratorio"
RECURSAO="no"              # no = so responde o proprio dominio | yes = resolve nomes externos
REVERSA="s"                # s = cria zona reversa (dig -x)
DEFINIR_HOSTNAME="s"       # s = hostnamectl set-hostname ns1.DOMINIO
DNS_LOCAL="n"              # s = aponta o DNS da propria VM para ela mesma (nmcli)
# Registros extras. Formatos:  "a NOME IP"   "cname NOME DESTINO"   "mx NOME"
REGISTROS=(
    # "a app 192.168.5.50"
    # "cname blog www"
    # "mx mail"
)
######################################################################

############################ TAREFAS EXTRAS ##########################
# Na Global serao pedidas 3 tarefas a mais. Escreva os comandos de cada
# uma DENTRO das funcoes abaixo (so isso). Elas rodam sozinhas, depois do
# firewall e dos servicos e antes dos testes finais.
# Exemplos prontos (copie para dentro da funcao):
#   Criar usuario ......: id aluno &>/dev/null || useradd aluno
#   Criar pasta ........: mkdir -p /srv/compartilhada && chmod 775 /srv/compartilhada
#   Abrir uma porta ....: firewall-cmd --permanent --add-port=8080/tcp && firewall-cmd --reload
#   Instalar FTP .......: dnf install -y vsftpd && systemctl enable --now vsftpd
#                         firewall-cmd --permanent --add-service=ftp && firewall-cmd --reload
tarefa_extra_1() {
    info "Tarefa extra 1: (vazia - escreva os comandos aqui)"
    :
}
tarefa_extra_2() {
    info "Tarefa extra 2: (vazia - escreva os comandos aqui)"
    :
}
tarefa_extra_3() {
    info "Tarefa extra 3: (vazia - escreva os comandos aqui)"
    :
}
######################################################################

AUTO="n"
LOG="/root/gs.log"
EXTRAS=""
FALHAS=0

# Mensagens padronizadas na tela
info()  { echo "[INFO]  $*"; }
aviso() { echo "[AVISO] $*"; }
erro()  { echo "[ERRO]  $*"; }

uso() { sed -n '3,/^# =====/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0; }

while getopts ":yd:i:u:h" OPC; do
    case "$OPC" in
        y) AUTO="s" ;;
        d) DOMINIO="$OPTARG" ;;
        i) IP="$OPTARG" ;;
        u) SITE_URL="$OPTARG"; SITE_MODO="url" ;;
        h) uso ;;
        *) echo "Opcao invalida. Use -h."; exit 1 ;;
    esac
done

if [ "$(id -u)" != "0" ]; then
    echo "Execute com sudo ou como root."
    exit 1
fi

# ---------------------------- funcoes ----------------------------
ip_valido() {
    local o
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

detectar_ip() {
    local det outro
    det=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    if [ -z "$det" ]; then
        det=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | head -n1)
    fi
    # NAT do VirtualBox (10.0.N.15, onde N muda conforme a placa): o Windows
    # nao alcanca esse IP. Se existir outro IP (ex.: Host-Only 192.168.56.x),
    # prefere o outro.
    if [[ "$det" =~ ^10\.0\.[0-9]+\.15$ ]]; then
        outro=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -v -E '^10\.0\.[0-9]+\.15$' | head -n1)
        [ -n "$outro" ] && det="$outro"
    fi
    echo "$det"
}

add_registro() {
    local tipo="${1,,}" nome="$2" valor="$3" alvo
    case "$tipo" in
        a)
            if [[ "$nome" =~ ^[a-zA-Z0-9-]+$ ]] && ip_valido "$valor"; then
                EXTRAS+="$nome IN A $valor"$'\n'
            else
                echo "Registro A invalido: $nome $valor"; return 1
            fi ;;
        cname)
            if [[ "$nome" =~ ^[a-zA-Z0-9-]+$ && "$valor" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                case "$valor" in
                    *.)            alvo="$valor" ;;
                    *."$DOMINIO")  alvo="${valor}." ;;
                    *)             alvo="${valor}.${DOMINIO}." ;;
                esac
                EXTRAS+="$nome IN CNAME $alvo"$'\n'
            else
                echo "Registro CNAME invalido: $nome $valor"; return 1
            fi ;;
        mx)
            if [[ "$nome" =~ ^[a-zA-Z0-9-]+$ ]]; then
                EXTRAS+="@ IN MX 10 ${nome}.${DOMINIO}."$'\n'
                EXTRAS+="$nome IN A $IP"$'\n'
            else
                echo "Registro MX invalido: $nome"; return 1
            fi ;;
        *) echo "Tipo de registro desconhecido: $tipo"; return 1 ;;
    esac
}

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  [OK]     $desc"
    else
        echo "  [FALHOU] $desc"
        FALHAS=$((FALHAS + 1))
    fi
}

gerar_pagina_local() {
    local rev_txt rec_txt host_txt
    rev_txt="Desativada nesta execu&ccedil;&atilde;o."
    [ "$REVERSA" = "s" ] && rev_txt="Consulta inversa: <code>$IP</code> &rarr; <code>www.$DOMINIO</code> (teste com <code>dig -x</code>)."
    rec_txt="desligada (s&oacute; responde o pr&oacute;prio dom&iacute;nio)"
    [ "$RECURSAO" = "yes" ] && rec_txt="ligada (resolve nomes externos)"
    host_txt="$(hostname)"
    [ "$DEFINIR_HOSTNAME" = "s" ] && host_txt="ns1.$DOMINIO"

    cat > /var/www/html/index.html <<FIM
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Parab&eacute;ns! Servidor no ar - $SITE_TITULO</title>
<style>
  :root { --bg1:#0b1f3a; --bg2:#13366b; --acc:#2dd4bf; --acc2:#60a5fa;
          --card:rgba(255,255,255,.07); --line:rgba(255,255,255,.14);
          --txt:#eaf2ff; --mut:#a9bbd6; }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; color:var(--txt); line-height:1.55;
         font-family:"Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         background: radial-gradient(1100px 560px at 85% -10%, #1f56a8 0%, transparent 60%),
                     linear-gradient(160deg, var(--bg1), var(--bg2)); background-color:var(--bg2); }
  html { background:var(--bg2); }
  .wrap { max-width:1040px; margin:0 auto; padding:44px 20px 60px; }
  .brand { text-align:center; color:var(--mut); letter-spacing:.18em; text-transform:uppercase;
           font-size:.78rem; margin-bottom:22px; }
  .hero { text-align:center; padding:8px 0 30px; }
  .check { width:104px; height:104px; margin:0 auto 22px; border-radius:50%;
           background:linear-gradient(135deg,var(--acc),var(--acc2));
           display:flex; align-items:center; justify-content:center;
           box-shadow:0 0 0 10px rgba(45,212,191,.15), 0 14px 40px rgba(45,212,191,.35);
           animation:pop .7s cubic-bezier(.2,1.4,.4,1) both; }
  .check svg { width:56px; height:56px; }
  .check path { stroke:#06223a; stroke-width:6; fill:none; stroke-linecap:round; stroke-linejoin:round;
                stroke-dasharray:60; stroke-dashoffset:60; animation:draw .6s .45s ease forwards; }
  @keyframes pop { from { transform:scale(.3); opacity:0; } to { transform:scale(1); opacity:1; } }
  @keyframes draw { to { stroke-dashoffset:0; } }
  h1 { font-size:clamp(2rem, 5vw, 3.2rem); margin:0 0 10px; letter-spacing:-.02em; }
  h1 span { background:linear-gradient(90deg,var(--acc),var(--acc2)); -webkit-background-clip:text;
            background-clip:text; color:transparent; }
  .sub { color:var(--mut); font-size:1.12rem; max-width:640px; margin:0 auto 20px; }
  .pills { display:flex; flex-wrap:wrap; gap:10px; justify-content:center; }
  .pill { padding:7px 16px; border-radius:999px; font-size:.9rem; border:1px solid var(--line);
          background:var(--card); }
  .pill::before { content:""; display:inline-block; width:9px; height:9px; margin-right:8px;
                  border-radius:50%; background:#34d399; box-shadow:0 0 10px #34d399; }
  h2 { font-size:1.35rem; margin:44px 0 16px; }
  h2::after { content:""; display:block; width:54px; height:3px; margin-top:8px; border-radius:3px;
              background:linear-gradient(90deg,var(--acc),var(--acc2)); }
  .info { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:14px; }
  .box { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:16px 18px; }
  .box small { display:block; color:var(--mut); font-size:.75rem; text-transform:uppercase; letter-spacing:.1em; }
  .box b { font-size:1.08rem; word-break:break-all; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:16px; }
  .step { position:relative; background:var(--card); border:1px solid var(--line); border-radius:16px;
          padding:20px 20px 18px 20px; transition:transform .2s, border-color .2s; }
  .step:hover { transform:translateY(-4px); border-color:var(--acc); }
  .num { display:inline-flex; align-items:center; justify-content:center; width:34px; height:34px;
         border-radius:10px; font-weight:700; color:#06223a; margin-bottom:10px;
         background:linear-gradient(135deg,var(--acc),var(--acc2)); }
  .step h3 { margin:0 0 6px; font-size:1.05rem; }
  .step p { margin:0; color:var(--mut); font-size:.95rem; }
  code { background:rgba(0,0,0,.35); padding:2px 7px; border-radius:6px; font-family:Consolas, monospace;
         font-size:.88em; color:#bdf3ea; }
  pre { margin:0; background:rgba(0,0,0,.4); border:1px solid var(--line); border-radius:14px;
        padding:18px 20px; overflow-x:auto; color:#bdf3ea; font-family:Consolas, monospace; font-size:.92rem; }
  pre i { color:var(--mut); font-style:normal; }
  footer { margin-top:50px; text-align:center; color:var(--mut); font-size:.85rem; }
</style>
</head>
<body>
<div class="wrap">

  <div class="brand">$SITE_TITULO</div>

  <header class="hero">
    <div class="check">
      <svg viewBox="0 0 64 64"><path d="M14 33 L27 46 L51 18"/></svg>
    </div>
    <h1>Parab&eacute;ns, voc&ecirc; <span>subiu o servidor!</span></h1>
    <p class="sub">Se voc&ecirc; est&aacute; lendo esta p&aacute;gina, o Apache est&aacute; respondendo e o DNS est&aacute; configurado.
       Tudo isso foi feito automaticamente pelo script <code>Definitivo_Supremo.sh</code>.</p>
    <div class="pills">
      <span class="pill">Apache no ar</span>
      <span class="pill">BIND (DNS) no ar</span>
      <span class="pill">Firewall liberado</span>
    </div>
  </header>

  <h2>Dados deste servidor</h2>
  <section class="info">
    <div class="box"><small>Dom&iacute;nio</small><b>$DOMINIO</b></div>
    <div class="box"><small>Site</small><b>www.$DOMINIO</b></div>
    <div class="box"><small>IP da VM</small><b>$IP</b></div>
    <div class="box"><small>Hostname</small><b>$host_txt</b></div>
    <div class="box"><small>Recurs&atilde;o DNS</small><b>$RECURSAO</b></div>
    <div class="box"><small>Configurado em</small><b>$(date '+%d/%m/%Y %H:%M')</b></div>
  </section>

  <h2>O que o script fez, passo a passo</h2>
  <section class="grid">
    <article class="step"><div class="num">1</div><h3>Fez backup</h3>
      <p>Copiou o <code>named.conf</code> e o <code>httpd.conf</code> originais para <code>/root/backup-gs-$DATA</code>, para voc&ecirc; poder voltar atr&aacute;s.</p></article>
    <article class="step"><div class="num">2</div><h3>Instalou os pacotes</h3>
      <p>Instalou BIND (DNS), Apache (web), firewalld e as ferramentas de teste usando o <code>dnf</code>.</p></article>
    <article class="step"><div class="num">3</div><h3>Configurou o DNS</h3>
      <p>Criou a zona <code>$DOMINIO</code> com os registros NS, A e <code>www</code>. Recurs&atilde;o $rec_txt. Validou com <code>named-checkzone</code>.</p></article>
    <article class="step"><div class="num">4</div><h3>Criou a zona reversa</h3>
      <p>$rev_txt</p></article>
    <article class="step"><div class="num">5</div><h3>Configurou o Apache</h3>
      <p>Definiu o <code>ServerName</code>, escondeu a vers&atilde;o do servidor (<code>ServerTokens Prod</code>) e validou com <code>httpd -t</code>.</p></article>
    <article class="step"><div class="num">6</div><h3>Publicou este site</h3>
      <p>Gerou esta p&aacute;gina em <code>/var/www/html/index.html</code> e ajustou o SELinux com <code>restorecon</code>.</p></article>
    <article class="step"><div class="num">7</div><h3>Liberou o firewall</h3>
      <p>Abriu os servi&ccedil;os <code>http</code>, <code>dns</code> e <code>ssh</code> no firewalld, de forma permanente.</p></article>
    <article class="step"><div class="num">8</div><h3>Ativou no boot</h3>
      <p>Habilitou <code>named</code> e <code>httpd</code> para subirem sozinhos quando a VM reiniciar.</p></article>
    <article class="step"><div class="num">9</div><h3>Testou tudo</h3>
      <p>Verificou servi&ccedil;os, HTTP e DNS, mostrou a tabela de <code>[OK]</code> e salvou o log em <code>/root/gs.log</code>.</p></article>
  </section>

  <h2>Teste voc&ecirc; mesmo</h2>
  <pre><i># na VM</i>
systemctl is-active named httpd
dig @127.0.0.1 www.$DOMINIO +short
dig @127.0.0.1 -x $IP +short
curl -I http://127.0.0.1

<i># no Windows (PowerShell)</i>
nslookup www.$DOMINIO $IP</pre>

  <footer>
    P&aacute;gina gerada automaticamente pelo <b>Definitivo_Supremo.sh</b> &middot; AlmaLinux &middot; BIND + Apache
  </footer>
</div>
</body>
</html>
FIM
}

# Baixa o template HTML da Internet e publica como pagina padrao do Apache.
# Aceita o link de uma pagina (.html) ou de um pacote (.zip) com o template.
# Se o download falhar, publica a pagina local para o script continuar.
baixar_site() {
    local origem idx raiz
    if [[ ! "$SITE_URL" =~ ^https?://[^/]+ ]]; then
        aviso "Link invalido ($SITE_URL). Usando a pagina local."
        gerar_pagina_local; return
    fi

    # Caso 1: pacote .zip com o template completo (HTML + CSS + imagens)
    case "${SITE_URL%%\?*}" in
        *.zip)
            info "Baixando o template (.zip) de $SITE_URL ..."
            rm -rf /tmp/gs-tpl /tmp/gs-tpl.zip
            mkdir -p /tmp/gs-tpl
            if curl -fsSL --max-time 120 "$SITE_URL" -o /tmp/gs-tpl.zip \
               && unzip -q -o /tmp/gs-tpl.zip -d /tmp/gs-tpl; then
                # Se houver mais de um index.html, usa o mais proximo da raiz do pacote
                idx=$(find /tmp/gs-tpl -name index.html | awk '{print gsub("/","/"), $0}' | sort -n | head -n1 | cut -d' ' -f2-)
                if [ -n "$idx" ]; then
                    raiz=$(dirname "$idx")
                    cp -a "$raiz"/. /var/www/html/
                    info "Template publicado em /var/www/html"
                    return
                fi
                aviso "O .zip nao tem index.html."
            else
                aviso "Nao consegui baixar ou abrir o .zip."
            fi
            aviso "Usando a pagina local para NAO travar o resto da configuracao."
            gerar_pagina_local
            return ;;
    esac

    # Caso 2: uma unica pagina .html
    info "Baixando o template (.html) de $SITE_URL ..."
    if curl -fsSL --max-time 60 "$SITE_URL" -o /tmp/gs-site.html && [ -s /tmp/gs-site.html ]; then
        cp /tmp/gs-site.html /var/www/html/index.html
        origem=$(echo "$SITE_URL" | sed -E 's|^(https?://[^/]+).*|\1/|')
        # CSS e imagens usam caminhos do site original: a tag base aponta para ele
        sed -i "0,/<head[^>]*>/s|<head[^>]*>|&<base href=\"$origem\">|" /var/www/html/index.html
        if [ "$BANNER_LAB" = "s" ]; then
            # Faixa avisando que e uma copia de laboratorio
            sed -i '0,/<body[^>]*>/s|<body[^>]*>|&<div style="background:#ffedb3;color:#222;padding:12px;text-align:center;font:16px Arial">COPIA PARA LABORATORIO - nao e o site oficial. Nao informe dados pessoais.</div>|' /var/www/html/index.html
        fi
        info "Template publicado a partir de $SITE_URL"
    else
        aviso "Nao consegui baixar $SITE_URL (sem internet ou bloqueado)."
        aviso "Usando a pagina local para NAO travar o resto da configuracao."
        gerar_pagina_local
    fi
}

# ---------------------------- entrada de dados ----------------------------
echo "===================================="
echo "   DEFINITIVO SUPREMO - DNS e Apache no AlmaLinux"
echo "===================================="

if [ "$AUTO" != "s" ]; then
    echo "O script vai instalar o BIND e o Apache."
    read -r -p "Deseja continuar? (s/n): " R
    [ "$R" = "s" ] || { echo "Cancelado."; exit 0; }
    read -r -p "Dominio [$DOMINIO]: " R
    DOMINIO="${R:-$DOMINIO}"
fi

DOMINIO="${DOMINIO,,}"
if ! [[ "$DOMINIO" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]]; then
    echo "Dominio invalido: $DOMINIO"
    exit 1
fi

if [ -z "$IP" ]; then
    IP="$(detectar_ip)"
fi
if [ "$AUTO" != "s" ]; then
    echo "IPs encontrados nesta VM: $(hostname -I 2>/dev/null)"
    read -r -p "IP da VM para o DNS [$IP]: " R
    IP="${R:-$IP}"
fi
if ! ip_valido "$IP"; then
    echo "IP invalido ou nao detectado: '$IP'. Use -i IP ou preencha o bloco CONFIGURACAO."
    exit 1
fi

if [ "$AUTO" != "s" ]; then
    echo
    echo "Site a publicar: 1) template baixado da Internet (.html ou .zip)  2) pagina local do script"
    read -r -p "Escolha [1]: " R
    if [ "$R" = "2" ]; then
        SITE_MODO="local"
        read -r -p "Titulo da pagina [$SITE_TITULO]: " R
        SITE_TITULO="${R:-$SITE_TITULO}"
    else
        SITE_MODO="url"
        read -r -p "Link do template [$SITE_URL]: " R
        SITE_URL="${R:-$SITE_URL}"
    fi
fi

# Registros do bloco de configuracao
for linha in "${REGISTROS[@]}"; do
    # shellcheck disable=SC2086
    add_registro $linha
done

# Registros digitados
if [ "$AUTO" != "s" ]; then
    while true; do
        echo
        read -r -p "Adicionar registro DNS? (a/cname/mx/fim): " TIPO
        case "${TIPO,,}" in
            a)
                read -r -p "Nome (ex: app): " NOME
                read -r -p "IP do registro: " VALOR
                add_registro a "$NOME" "$VALOR" ;;
            cname)
                read -r -p "Apelido (ex: blog): " NOME
                read -r -p "Destino (ex: www): " VALOR
                add_registro cname "$NOME" "$VALOR" ;;
            mx)
                read -r -p "Nome do servidor de email (ex: mail): " NOME
                add_registro mx "$NOME" ;;
            fim|"") break ;;
            *) echo "Digite a, cname, mx ou fim." ;;
        esac
    done
fi

# Remove linhas repetidas (rodar duas vezes nao duplica nada)
EXTRAS="$(printf '%s' "$EXTRAS" | awk 'NF && !seen[$0]++')"

echo
echo "------------- RESUMO -------------"
echo "Dominio ........: $DOMINIO"
echo "IP da VM .......: $IP"
echo "Site ...........: $SITE_MODO"
echo "Recursao DNS ...: $RECURSAO"
echo "Zona reversa ...: $REVERSA"
echo "Hostname .......: $DEFINIR_HOSTNAME"
[ -n "$EXTRAS" ] && { echo "Registros extras:"; echo "$EXTRAS" | sed 's/^/   /'; }
echo "----------------------------------"
if [ "$AUTO" != "s" ]; then
    read -r -p "Confirmar as alteracoes? (s/n): " R
    [ "$R" = "s" ] || { echo "Cancelado."; exit 0; }
fi

# A partir daqui tudo vai tambem para o log
exec > >(tee -a "$LOG") 2>&1
echo "=== Definitivo Supremo iniciado em $(date) ==="

# ---------------------------- 1 - pacotes ----------------------------
info "Passo 1 - Instalando BIND e Apache (pode demorar)..."
dnf install -y bind bind-utils httpd curl firewalld policycoreutils unzip || {
    erro "O dnf falhou. Confira a internet da VM (ping -c2 8.8.8.8 e ping -c2 google.com)."
    exit 1
}

DATA=$(date +%Y%m%d-%H%M%S)
mkdir -p "/root/backup-gs-$DATA"
cp /etc/named.conf /etc/httpd/conf/httpd.conf "/root/backup-gs-$DATA/"
echo "Backup em /root/backup-gs-$DATA"

# ---------------------------- 2 - DNS ----------------------------
info "Passo 2 - Configurando DNS..."
sed -i 's/listen-on port 53.*;/listen-on port 53 { any; };/' /etc/named.conf
sed -i 's/allow-query.*;/allow-query { any; };/' /etc/named.conf
sed -i "s/recursion \(yes\|no\);/recursion $RECURSAO;/" /etc/named.conf

ZONA_DIRETA="gs-$DOMINIO.zone"
if ! grep -q "zone \"$DOMINIO\"" /etc/named.conf; then
cat >> /etc/named.conf <<FIM

zone "$DOMINIO" IN {
    type master;
    file "$ZONA_DIRETA";
    allow-transfer { none; };
};
FIM
fi

SERIAL=$(date +%s)

cat > "/var/named/$ZONA_DIRETA" <<FIM
\$TTL 300
@ IN SOA ns1.$DOMINIO. admin.$DOMINIO. (
    $SERIAL
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
chown root:named "/var/named/$ZONA_DIRETA"
chmod 640 "/var/named/$ZONA_DIRETA"
restorecon "/var/named/$ZONA_DIRETA"
named-checkzone "$DOMINIO" "/var/named/$ZONA_DIRETA" || exit 1

# Zona reversa (assume rede /24: a.b.c.0)
if [ "$REVERSA" = "s" ]; then
    IFS=. read -r O1 O2 O3 O4 <<< "$IP"
    ZONA_REV="$O3.$O2.$O1.in-addr.arpa"
    ARQ_REV="gs-rev-$O3.$O2.$O1.zone"
    if ! grep -q "zone \"$ZONA_REV\"" /etc/named.conf; then
cat >> /etc/named.conf <<FIM

zone "$ZONA_REV" IN {
    type master;
    file "$ARQ_REV";
    allow-transfer { none; };
};
FIM
    fi
cat > "/var/named/$ARQ_REV" <<FIM
\$TTL 300
@ IN SOA ns1.$DOMINIO. admin.$DOMINIO. (
    $SERIAL
    3600
    1800
    7200
    600
)
@   IN NS ns1.$DOMINIO.
$O4 IN PTR www.$DOMINIO.
FIM
    chown root:named "/var/named/$ARQ_REV"
    chmod 640 "/var/named/$ARQ_REV"
    restorecon "/var/named/$ARQ_REV"
    named-checkzone "$ZONA_REV" "/var/named/$ARQ_REV" || exit 1
fi

named-checkconf -z || exit 1

# ---------------------------- 3 - Apache ----------------------------
info "Passo 3 - Configurando Apache..."
sed -i 's/^Listen 81$/Listen 80/' /etc/httpd/conf/httpd.conf
cat > /etc/httpd/conf.d/gs-security.conf <<FIM
ServerName www.$DOMINIO
ServerTokens Prod
ServerSignature Off
FIM

# ---------------------------- 4 - Site ----------------------------
info "Passo 4 - Publicando o site (modo: $SITE_MODO)..."
if [ "$SITE_MODO" = "url" ]; then
    baixar_site
else
    gerar_pagina_local
fi
chmod 644 /var/www/html/index.html
restorecon -R /var/www/html
httpd -t || exit 1

# ---------------------------- 5 - Firewall ----------------------------
info "Passo 5 - Firewall: liberando DNS, HTTP e SSH..."
systemctl enable --now firewalld || exit 1
firewall-cmd --permanent --add-service=http --add-service=dns --add-service=ssh
firewall-cmd --reload

# ---------------------------- 6 - Servicos ----------------------------
info "Passo 6 - Iniciando os servicos..."
systemctl enable named httpd
if ! systemctl restart named httpd; then
    erro "Falha ao iniciar. Veja: journalctl -xeu named  |  journalctl -xeu httpd"
    exit 1
fi

# ---------------------------- 7 - Extras opcionais ----------------------------
if [ "$DEFINIR_HOSTNAME" = "s" ]; then
    info "Passo 7a - Definindo hostname: ns1.$DOMINIO"
    hostnamectl set-hostname "ns1.$DOMINIO"
fi

if [ "$DNS_LOCAL" = "s" ]; then
    info "Passo 7b - Apontando o DNS da VM para ela mesma..."
    IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$IFACE" '$2==d{print $1; exit}')
    if [ -n "$CON" ]; then
        # 8.8.8.8 como reserva: sem ele a VM nao resolveria nomes externos (dnf, curl)
        nmcli con mod "$CON" ipv4.dns "$IP,8.8.8.8" ipv4.dns-search "$DOMINIO" ipv4.ignore-auto-dns yes
        nmcli device reapply "$IFACE"
    else
        aviso "nao achei a conexao do NetworkManager. Configure o DNS manualmente."
    fi
fi

# ---------------------------- 7c - Tarefas extras da Global ----------------------------
info "Passo 7c - Executando as tarefas extras"
tarefa_extra_1
tarefa_extra_2
tarefa_extra_3

# ---------------------------- 8 - Testes ----------------------------
info "Passo 8 - Testando (aguarde 3s)..."
sleep 3
echo
echo "========== RESULTADO DOS TESTES =========="
check "named ativo"                      systemctl is-active --quiet named
check "httpd ativo"                      systemctl is-active --quiet httpd
check "named habilitado no boot"         systemctl is-enabled --quiet named
check "httpd habilitado no boot"         systemctl is-enabled --quiet httpd
check "named-checkconf -z"               named-checkconf -z
check "HTTP 200 em 127.0.0.1"            test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1)" = "200"
check "HTTP 200 em $IP"                  test "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP")" = "200"
check "dig www.$DOMINIO (local)"         test "$(dig @127.0.0.1 +short "www.$DOMINIO")" = "$IP"
check "dig www.$DOMINIO (pelo IP $IP)"   test "$(dig @"$IP" +short "www.$DOMINIO")" = "$IP"
if [ "$REVERSA" = "s" ]; then
    check "dig -x $IP (reversa)"         test "$(dig @127.0.0.1 +short -x "$IP")" = "www.$DOMINIO."
fi
echo "=========================================="
if [ "$FALHAS" -eq 0 ]; then
    echo "TUDO OK."
else
    echo "$FALHAS teste(s) falharam. Veja o log: $LOG"
fi

echo
echo "Site ........: http://$IP   (ou http://www.$DOMINIO se o PC usar este DNS)"
echo "No Windows ..: nslookup www.$DOMINIO $IP"
echo "Log .........: $LOG"
echo "Backup ......: /root/backup-gs-$DATA"
sleep 1
[ "$FALHAS" -eq 0 ] || exit 1
