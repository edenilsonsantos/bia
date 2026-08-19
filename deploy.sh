#!/bin/bash
set -e

./build.sh

echo "Ajustando minimumHealthyPercent para 0% para liberar memória no deploy..."
aws ecs update-service \
  --cluster cluster-bia \
  --service service-bia \
  --deployment-configuration "minimumHealthyPercent=0,maximumPercent=100" \
  --region us-east-1 > /dev/null

echo "Forçando novo deployment..."
aws ecs update-service \
  --cluster cluster-bia \
  --service service-bia \
  --force-new-deployment \
  --region us-east-1 > /dev/null

echo "Aguardando serviço estabilizar..."
aws ecs wait services-stable \
  --cluster cluster-bia \
  --services service-bia \
  --region us-east-1

echo "Restaurando minimumHealthyPercent para 50%..."
aws ecs update-service \
  --cluster cluster-bia \
  --service service-bia \
  --deployment-configuration "minimumHealthyPercent=50,maximumPercent=100" \
  --region us-east-1 > /dev/null

echo "Deploy concluído com sucesso!"
