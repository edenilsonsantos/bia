#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy e Rollback para ECS | Projeto BIA
# =============================================================================
# Uso:
#   ./scripts/deploy.sh            → menu interativo
#   ./scripts/deploy.sh deploy 1   → deploy sem ALB direto
#   ./scripts/deploy.sh deploy 2   → deploy com ALB direto
#   ./scripts/deploy.sh rollback 1 → rollback sem ALB direto
#   ./scripts/deploy.sh rollback 2 → rollback com ALB direto
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configurações do projeto
# ---------------------------------------------------------------------------
AWS_REGION="us-east-1"
ECR_REGISTRY="679965617849.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="bia"
ECR_REPO_URI="${ECR_REGISTRY}/${ECR_REPO}"
CONTAINER_NAME="bia"
CONTAINER_PORT=8080

# Recursos por ambiente
# Ambiente 1: sem ALB
CLUSTER_1="cluster-bia"
SERVICE_1="service-bia"
TASK_DEF_FAMILY_1="task-def-bia"

# Ambiente 2: com ALB
CLUSTER_2="cluster-bia-alb"
SERVICE_2="service-bia-alb"
TASK_DEF_FAMILY_2="task-def-bia-alb"

# Quantas tags recentes mostrar no rollback
ROLLBACK_LIST_SIZE=10

# ---------------------------------------------------------------------------
# Cores para output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Funções utilitárias
# ---------------------------------------------------------------------------
log()     { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERRO]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

check_dependencies() {
    local missing=()
    for cmd in aws docker git jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Dependências faltando: ${missing[*]}"
        error "Instale com: sudo yum install -y ${missing[*]}"
        exit 1
    fi
}

# Resolve cluster, service e task definition family pelo número do ambiente
resolve_env() {
    local env_num="$1"
    case "$env_num" in
        1)
            CLUSTER="$CLUSTER_1"
            SERVICE="$SERVICE_1"
            TASK_DEF_FAMILY="$TASK_DEF_FAMILY_1"
            ENV_LABEL="sem ALB (cluster-bia)"
            ;;
        2)
            CLUSTER="$CLUSTER_2"
            SERVICE="$SERVICE_2"
            TASK_DEF_FAMILY="$TASK_DEF_FAMILY_2"
            ENV_LABEL="com ALB (cluster-bia-alb)"
            ;;
        *)
            error "Ambiente inválido: $env_num. Use 1 (sem ALB) ou 2 (com ALB)."
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Menu: escolha de ambiente
# ---------------------------------------------------------------------------
menu_ambiente() {
    echo ""
    echo -e "${BOLD}Escolha o ambiente de deploy:${NC}"
    echo "  1) Sem ALB  → cluster: ${CLUSTER_1} | service: ${SERVICE_1}"
    echo "  2) Com ALB  → cluster: ${CLUSTER_2} | service: ${SERVICE_2}"
    echo ""
    read -rp "Ambiente [1/2]: " env_choice
    case "$env_choice" in
        1|2) echo "$env_choice" ;;
        *) error "Opção inválida."; exit 1 ;;
    esac
}

# Menu: escolha de ação
menu_acao() {
    echo ""
    echo -e "${BOLD}O que deseja fazer?${NC}"
    echo "  1) Deploy   → build + push ECR + nova task definition + atualizar service"
    echo "  2) Rollback → escolher image tag existente + atualizar service"
    echo ""
    read -rp "Ação [1/2]: " acao_choice
    case "$acao_choice" in
        1) echo "deploy" ;;
        2) echo "rollback" ;;
        *) error "Opção inválida."; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# ECR: login
# ---------------------------------------------------------------------------
ecr_login() {
    header "Login no ECR"
    aws ecr get-login-password --region "$AWS_REGION" \
        | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    success "Login no ECR realizado."
}

# ---------------------------------------------------------------------------
# DEPLOY
# ---------------------------------------------------------------------------
run_deploy() {
    local env_num="$1"
    resolve_env "$env_num"

    header "Deploy — Ambiente: ${ENV_LABEL}"

    # 1. Commit hash (tag da imagem)
    if ! git -C "$(dirname "$0")/.." rev-parse HEAD &>/dev/null; then
        error "Não foi possível obter o commit hash. Verifique se está em um repositório git."
        exit 1
    fi
    local commit_hash
    commit_hash=$(git -C "$(dirname "$0")/.." rev-parse --short=7 HEAD)
    local image_tag="${commit_hash}"
    local image_uri="${ECR_REPO_URI}:${image_tag}"

    log "Commit hash: ${commit_hash}"
    log "Image tag:   ${image_tag}"
    log "Image URI:   ${image_uri}"

    # 2. Build da imagem
    header "Build da imagem Docker"
    local project_root
    project_root="$(cd "$(dirname "$0")/.." && pwd)"
    docker build -t "${ECR_REPO_URI}:latest" "$project_root"
    docker tag "${ECR_REPO_URI}:latest" "${image_uri}"
    success "Build concluído: ${image_tag}"

    # 3. Push para ECR
    ecr_login
    header "Push para ECR"
    docker push "${ECR_REPO_URI}:latest"
    docker push "${image_uri}"
    success "Push concluído: ${image_tag} e latest"

    # 4. Criar nova revisão da Task Definition
    _register_task_def "$image_uri" "$image_tag" "$env_num"

    # 5. Atualizar ECS Service
    _update_service

    success "Deploy finalizado! Ambiente: ${ENV_LABEL} | Tag: ${image_tag}"
}

# ---------------------------------------------------------------------------
# ROLLBACK
# ---------------------------------------------------------------------------
run_rollback() {
    local env_num="$1"
    resolve_env "$env_num"

    header "Rollback — Ambiente: ${ENV_LABEL}"

    # 1. Listar tags disponíveis no ECR (excluindo 'latest'), ordenadas por data de push
    log "Buscando imagens disponíveis no ECR..."
    local tags_json
    tags_json=$(aws ecr describe-images \
        --region "$AWS_REGION" \
        --repository-name "$ECR_REPO" \
        --query 'imageDetails[?imageTags!=`null`].[imagePushedAt,imageTags[0]]' \
        --output json \
        | jq '[.[] | select(.[1] != "latest")] | sort_by(.[0]) | reverse')

    local count
    count=$(echo "$tags_json" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        warn "Nenhuma imagem com tag encontrada no ECR (exceto 'latest')."
        warn "Execute um deploy primeiro para criar tags versionadas."
        exit 1
    fi

    echo ""
    echo -e "${BOLD}Imagens disponíveis para rollback:${NC}"
    echo ""
    printf "  %-4s %-20s %-30s\n" "Nº" "Tag (commit hash)" "Data de push"
    printf "  %-4s %-20s %-30s\n" "---" "-------------------" "-----------------------------"

    local limit=$ROLLBACK_LIST_SIZE
    [[ "$count" -lt "$limit" ]] && limit="$count"

    for i in $(seq 0 $((limit - 1))); do
        local pushed_at tag
        pushed_at=$(echo "$tags_json" | jq -r ".[$i][0]")
        tag=$(echo "$tags_json" | jq -r ".[$i][1]")
        printf "  %-4s %-20s %-30s\n" "$((i + 1))" "$tag" "$pushed_at"
    done

    echo ""
    read -rp "Escolha o número da tag para rollback [1-${limit}]: " tag_choice

    if ! [[ "$tag_choice" =~ ^[0-9]+$ ]] || [[ "$tag_choice" -lt 1 ]] || [[ "$tag_choice" -gt "$limit" ]]; then
        error "Opção inválida: $tag_choice"
        exit 1
    fi

    local selected_tag
    selected_tag=$(echo "$tags_json" | jq -r ".[$(( tag_choice - 1 ))][1]")
    local selected_image_uri="${ECR_REPO_URI}:${selected_tag}"

    log "Tag selecionada: ${selected_tag}"
    log "Image URI: ${selected_image_uri}"

    # 2. Verificar se existe task definition com essa tag
    _find_or_create_task_def "$selected_image_uri" "$selected_tag" "$env_num"

    # 3. Atualizar ECS Service
    _update_service

    success "Rollback finalizado! Ambiente: ${ENV_LABEL} | Tag: ${selected_tag}"
}

# ---------------------------------------------------------------------------
# Registrar nova Task Definition
# ---------------------------------------------------------------------------
_register_task_def() {
    local image_uri="$1"
    local image_tag="$2"
    local env_num="$3"

    header "Registrando nova Task Definition: ${TASK_DEF_FAMILY}"

    # Busca a task definition atual para reaproveitar configurações
    local current_td_json
    current_td_json=$(aws ecs describe-task-definition \
        --region "$AWS_REGION" \
        --task-definition "$TASK_DEF_FAMILY" \
        --query 'taskDefinition' \
        --output json 2>/dev/null || echo "null")

    local new_td_json

    if [[ "$current_td_json" == "null" ]]; then
        warn "Task Definition '${TASK_DEF_FAMILY}' não encontrada. Criando definição base..."
        new_td_json=$(_build_base_task_def "$image_uri" "$image_tag")
    else
        log "Task Definition atual encontrada. Criando nova revisão com image tag: ${image_tag}"
        # Atualiza a imagem do container e adiciona dockerLabel dentro do containerDefinition
        new_td_json=$(echo "$current_td_json" | jq \
            --arg img "$image_uri" \
            --arg tag "$image_tag" \
            --arg container "$CONTAINER_NAME" \
            '
            .containerDefinitions = (.containerDefinitions | map(
                if .name == $container then
                    .image = $img |
                    .dockerLabels = ((.dockerLabels // {}) + {"deploy.imageTag": $tag})
                else . end
            )) |
            del(
                .taskDefinitionArn, .revision, .status, .requiresAttributes,
                .compatibilities, .registeredAt, .registeredBy,
                .containerDefinitions[].environmentFiles,
                .containerDefinitions[].mountPoints,
                .containerDefinitions[].volumesFrom,
                .containerDefinitions[].ulimits,
                .containerDefinitions[].systemControls,
                .containerDefinitions[].logConfiguration.secretOptions
            )
            ')
    fi

    # Registra a nova task definition
    local new_td_arn
    new_td_arn=$(aws ecs register-task-definition \
        --region "$AWS_REGION" \
        --cli-input-json "$new_td_json" \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)

    NEW_TASK_DEF_ARN="$new_td_arn"
    success "Nova Task Definition registrada: ${new_td_arn}"
}

# Busca task definition existente com a tag ou cria uma nova
_find_or_create_task_def() {
    local image_uri="$1"
    local image_tag="$2"
    local env_num="$3"

    header "Verificando Task Definition para tag: ${image_tag}"

    # Lista revisões da task definition para encontrar uma que use esta tag
    local revisions_json
    revisions_json=$(aws ecs list-task-definitions \
        --region "$AWS_REGION" \
        --family-prefix "$TASK_DEF_FAMILY" \
        --sort DESC \
        --query 'taskDefinitionArns' \
        --output json 2>/dev/null || echo "[]")

    local matching_arn=""
    local arns_count
    arns_count=$(echo "$revisions_json" | jq 'length')

    if [[ "$arns_count" -gt 0 ]]; then
        log "Procurando task definition existente com tag '${image_tag}'..."
        for i in $(seq 0 $((arns_count - 1))); do
            local td_arn
            td_arn=$(echo "$revisions_json" | jq -r ".[$i]")
            local td_image
            td_image=$(aws ecs describe-task-definition \
                --region "$AWS_REGION" \
                --task-definition "$td_arn" \
                --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].image" \
                --output text 2>/dev/null || echo "")
            if echo "$td_image" | grep -q ":${image_tag}$"; then
                matching_arn="$td_arn"
                log "Task Definition existente encontrada para tag '${image_tag}': ${matching_arn}"
                break
            fi
        done
    fi

    if [[ -z "$matching_arn" ]]; then
        log "Nenhuma task definition existente para tag '${image_tag}'. Criando nova revisão..."
        _register_task_def "$image_uri" "$image_tag" "$env_num"
    else
        NEW_TASK_DEF_ARN="$matching_arn"
        success "Usando Task Definition existente: ${NEW_TASK_DEF_ARN}"
    fi
}

# Constrói task definition base quando não existe nenhuma ainda
_build_base_task_def() {
    local image_uri="$1"
    local image_tag="$2"

    jq -n \
        --arg family "$TASK_DEF_FAMILY" \
        --arg container "$CONTAINER_NAME" \
        --arg image "$image_uri" \
        --arg tag "$image_tag" \
        --argjson port "$CONTAINER_PORT" \
        '{
            "family": $family,
            "networkMode": "bridge",
            "containerDefinitions": [
                {
                    "name": $container,
                    "image": $image,
                    "cpu": 1024,
                    "memoryReservation": 400,
                    "portMappings": [
                        {
                            "containerPort": $port,
                            "hostPort": 0,
                            "protocol": "tcp"
                        }
                    ],
                    "essential": true,
                    "dockerLabels": {
                        "deploy.imageTag": $tag
                    },
                    "logConfiguration": {
                        "logDriver": "awslogs",
                        "options": {
                            "awslogs-group": "/ecs/task-def-bia",
                            "awslogs-region": "us-east-1",
                            "awslogs-stream-prefix": "bia"
                        }
                    }
                }
            ]
        }'
}

# ---------------------------------------------------------------------------
# Atualizar ECS Service
# ---------------------------------------------------------------------------
_update_service() {
    header "Atualizando ECS Service: ${SERVICE} no cluster ${CLUSTER}"
    log "Task Definition: ${NEW_TASK_DEF_ARN}"

    aws ecs update-service \
        --region "$AWS_REGION" \
        --cluster "$CLUSTER" \
        --service "$SERVICE" \
        --task-definition "$NEW_TASK_DEF_ARN" \
        --output json \
        | jq '{
            service: .service.serviceName,
            cluster: (.service.clusterArn | split("/")[-1]),
            status: .service.status,
            desiredCount: .service.desiredCount,
            taskDefinition: (.service.taskDefinition | split("/")[-1])
          }'

    success "Serviço atualizado. Aguardando estabilização..."
    log "(Isso pode levar alguns minutos dependendo da estratégia de deploy)"

    if aws ecs wait services-stable \
        --region "$AWS_REGION" \
        --cluster "$CLUSTER" \
        --services "$SERVICE" 2>/dev/null; then
        success "Serviço estabilizado com sucesso!"
    else
        warn "Timeout aguardando estabilização (pode ainda estar convergindo)."
        warn "Verifique o status com: aws ecs describe-services --cluster ${CLUSTER} --services ${SERVICE}"
    fi
}

# ---------------------------------------------------------------------------
# Mapeamento de argumento de ação para modo
# ---------------------------------------------------------------------------
_parse_action_arg() {
    local raw="$1"
    case "$raw" in
        deploy|1)   echo "deploy" ;;
        rollback|2) echo "rollback" ;;
        *) error "Ação inválida: '$raw'. Use 'deploy' ou 'rollback'."; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   BIA — Deploy / Rollback ECS            ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_dependencies

    local acao env_num

    # Aceita argumentos opcionais: ./deploy.sh [deploy|rollback] [1|2]
    if [[ $# -ge 2 ]]; then
        acao=$(_parse_action_arg "$1")
        env_num="$2"
        log "Modo: ${acao} | Ambiente: ${env_num}"
    elif [[ $# -eq 1 ]]; then
        acao=$(_parse_action_arg "$1")
        env_num=$(menu_ambiente)
    else
        acao=$(menu_acao)
        env_num=$(menu_ambiente)
    fi

    case "$acao" in
        deploy)   run_deploy   "$env_num" ;;
        rollback) run_rollback "$env_num" ;;
    esac
}

main "$@"
