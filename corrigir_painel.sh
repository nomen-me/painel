#!/usr/bin/env bash
# =============================================================================
#  corrigir_painel.sh — Painel servindo versão antiga mesmo depois de trocar o
#  arquivo na VPS.
#
#  CAUSA
#  O compose do Painel (seção 9.5 do instalar_nomen_completo.sh) monta um
#  ARQUIVO, não uma pasta:
#
#      - ./index.html:/usr/share/nginx/html/index.html:ro
#
#  Bind mount de arquivo único no Docker é resolvido por INODE no momento em
#  que o container é criado. Qualquer coisa que substitua o arquivo em vez de
#  reescrevê-lo no lugar cria um inode novo — e o container continua apontando
#  pro inode antigo, já apagado do diretório. O nginx segue servindo um arquivo
#  que não existe mais no host.
#
#  Substituem o inode: scp/sftp, vim/nano (gravam temporário + rename), git
#  checkout, e o próprio `sed -i` que a seção 9.5 roda logo depois do cp
#  (sed -i sempre reescreve e renomeia, mesmo quando não substitui nada).
#
#  Como `docker compose up -d` não recria um container cujo compose não mudou,
#  cada nova instalação do Painel entrega o arquivo novo pro host e mantém o
#  antigo dentro do container. É por isso que troca de navegador não resolve:
#  o problema não está em nenhum navegador, está no que o servidor devolve.
#
#  O QUE ESTE SCRIPT FAZ
#  1. Mede a realidade antes de mexer em nada: hash do arquivo no host, hash
#     do arquivo dentro do container e hash do que o HTTPS realmente devolve.
#  2. Troca o mount de arquivo único por mount de PASTA (./site), que o Docker
#     resolve por caminho e não por inode — trocar o arquivo passa a valer na
#     hora, sem recriar container.
#  3. Passa a servir com Cache-Control: no-store no index.html, pra que o
#     navegador nunca segure o painel entre deploys.
#  4. Recria o container e mede a realidade de novo.
#
#  NÃO destrói nada: /home/ubuntu/painel/index.html antigo é preservado.
#
#  USO
#    sudo bash corrigir_painel.sh painel.seudominio.com.br [caminho/do/painel.html]
#
#  O 2º argumento é opcional. Sem ele, o script republica o HTML que já está
#  na VPS (corrige só o mecanismo). Com ele, publica o arquivo informado.
# =============================================================================
set -euo pipefail

DOMINIO_PAINEL="${1:?Uso: sudo bash corrigir_painel.sh <painel.seudominio> [arquivo.html]}"
HTML_NOVO="${2:-}"
BASE="/home/ubuntu/painel"

log()  { echo -e "\n\033[1;36m› $*\033[0m"; }
ok()   { echo -e "  \033[1;32m✓\033[0m $*"; }
warn() { echo -e "  \033[1;33m!\033[0m $*"; }
fail() { echo -e "  \033[1;31m✗\033[0m $*"; exit 1; }

h12() { sha256sum "$1" 2>/dev/null | cut -c1-12 || echo "ausente"; }

# ---------------------------------------------------------------------------
# 0. Realidade ANTES — três medições independentes
# ---------------------------------------------------------------------------
log "Estado atual (antes de qualquer alteração)"

ARQ_HOST=""
for c in "$BASE/site/index.html" "$BASE/index.html"; do
  [ -f "$c" ] && ARQ_HOST="$c" && break
done

if [ -n "$ARQ_HOST" ]; then
  echo "  host      : $ARQ_HOST  → $(h12 "$ARQ_HOST")  (aba PDV: $(grep -c 'data-page="pdv"' "$ARQ_HOST" || true)x)"
else
  warn "Nenhum index.html encontrado em $BASE"
fi

if docker ps --format '{{.Names}}' | grep -qx painel; then
  HC=$(docker exec painel sha256sum /usr/share/nginx/html/index.html 2>/dev/null | cut -c1-12 || echo "erro")
  PC=$(docker exec painel grep -c 'data-page="pdv"' /usr/share/nginx/html/index.html 2>/dev/null || echo 0)
  echo "  container : /usr/share/nginx/html/index.html → ${HC}  (aba PDV: ${PC}x)"
else
  warn "Container 'painel' não está rodando."
fi

HH=$(curl -fsSL -H 'Cache-Control: no-cache' "https://${DOMINIO_PAINEL}" 2>/dev/null | tee /tmp/painel_http.html | sha256sum | cut -c1-12 || echo "erro")
PH=$(grep -c 'data-page="pdv"' /tmp/painel_http.html 2>/dev/null || echo 0)
echo "  HTTPS     : https://${DOMINIO_PAINEL} → ${HH}  (aba PDV: ${PH}x)"
echo
echo "  Hashes diferentes entre host e container = mount de inode obsoleto (a causa)."
echo "  Aba PDV 0x no host = o arquivo que está na VPS é antigo, e aí o problema"
echo "  é de qual arquivo foi copiado, não de cache."

# ---------------------------------------------------------------------------
# 1. Novo HTML (opcional) — validado ANTES de publicar
# ---------------------------------------------------------------------------
if [ -n "$HTML_NOVO" ]; then
  [ -f "$HTML_NOVO" ] || fail "Arquivo não existe: $HTML_NOVO"
  grep -q 'data-page="pdv"' "$HTML_NOVO" \
    || fail "O arquivo $HTML_NOVO não contém a aba Frente de Loja (data-page=\"pdv\"). Publicar isso não resolveria nada — confira qual arquivo você copiou pra VPS."
  ok "Arquivo de origem validado: contém a aba Frente de Loja"
fi

# ---------------------------------------------------------------------------
# 2. Mount de PASTA em vez de arquivo único
# ---------------------------------------------------------------------------
log "Reconfigurando o Painel para mount de pasta"
mkdir -p "$BASE/site" "$BASE/conf"

if [ -n "$HTML_NOVO" ]; then
  cp "$HTML_NOVO" "$BASE/site/index.html"
  ok "Publicado: $HTML_NOVO → $BASE/site/index.html"
elif [ -f "$BASE/site/index.html" ]; then
  ok "Mantido o index.html que já estava em $BASE/site/"
elif [ -f "$BASE/index.html" ]; then
  cp "$BASE/index.html" "$BASE/site/index.html"
  ok "Migrado $BASE/index.html → $BASE/site/index.html (o original fica onde está)"
else
  fail "Não há index.html para publicar. Rode de novo passando o arquivo como 2º argumento."
fi

# nginx: o painel é um arquivo único que muda a cada deploy. Revalidação
# obrigatória custa um HEAD; descobrir semanas depois que o navegador segurou
# a versão antiga custa muito mais.
cat > "$BASE/conf/default.conf" << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location = / {
        add_header Cache-Control "no-store, must-revalidate" always;
        expires -1;
    }
    location = /index.html {
        add_header Cache-Control "no-store, must-revalidate" always;
        expires -1;
    }
    location / {
        try_files $uri =404;
    }
}
EOF

cat > "$BASE/docker-compose.yml" << EOF
services:
  painel:
    image: nginx:alpine
    container_name: painel
    restart: always
    volumes:
      # Pasta, não arquivo: o Docker resolve por caminho, então trocar o
      # index.html dentro de ./site vale na hora, sem recriar o container.
      - ./site:/usr/share/nginx/html:ro
      - ./conf:/etc/nginx/conf.d:ro
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.painel.rule=Host(\`${DOMINIO_PAINEL}\`)"
      - "traefik.http.routers.painel.entrypoints=websecure"
      - "traefik.http.routers.painel.tls.certresolver=myresolver"
      - "traefik.http.routers.painel.priority=10"
      - "traefik.http.services.painel.loadbalancer.server.port=80"
networks:
  stack-network:
    external: true
EOF

cd "$BASE"
docker compose up -d --force-recreate
ok "Container 'painel' recriado com o mount novo"

# ---------------------------------------------------------------------------
# 3. Realidade DEPOIS
# ---------------------------------------------------------------------------
log "Estado depois"
sleep 3

HOST_H=$(h12 "$BASE/site/index.html")
CONT_H=$(docker exec painel sha256sum /usr/share/nginx/html/index.html | cut -c1-12)
curl -fsSL -H 'Cache-Control: no-cache' "https://${DOMINIO_PAINEL}" -o /tmp/painel_http2.html
HTTP_H=$(sha256sum /tmp/painel_http2.html | cut -c1-12)
PDV_H=$(grep -c 'data-page="pdv"' /tmp/painel_http2.html || true)

echo "  host      : ${HOST_H}"
echo "  container : ${CONT_H}"
echo "  HTTPS     : ${HTTP_H}"
echo "  aba Frente de Loja no que o HTTPS devolve: ${PDV_H}x"
echo

if [ "$HOST_H" = "$CONT_H" ] && [ "$CONT_H" = "$HTTP_H" ] && [ "${PDV_H}" != "0" ]; then
  ok "Host, container e HTTPS servem o mesmo arquivo, e a aba Frente de Loja está nele."
  echo
  echo "  Daqui em diante, publicar uma versão nova é só:"
  echo "    cp painel_novo.html ${BASE}/site/index.html"
  echo "  Vale imediatamente. Sem recriar container, sem limpar cache."
elif [ "${PDV_H}" = "0" ]; then
  warn "O servidor agora está coerente, mas o HTML publicado não tem a aba Frente de Loja."
  echo "  O problema não era cache: é o arquivo. Rode de novo passando o HTML correto:"
  echo "    sudo bash $0 ${DOMINIO_PAINEL} /root/synapse_painel_18-09e.html"
else
  warn "Ainda há divergência entre as três medições. Não declare resolvido."
  echo "  Verifique se existe outro roteador/proxy na frente do Traefik (Cloudflare"
  echo "  em modo proxied, por exemplo) segurando a resposta em cache de borda."
fi
