COMPOSE ?= docker compose

.DEFAULT_GOAL := help

.PHONY: help
help: ## Affiche cette aide
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: up
up: ## Démarre la stack en arrière-plan
	$(COMPOSE) up -d

.PHONY: down
down: ## Arrête la stack (les volumes sont conservés)
	$(COMPOSE) down

.PHONY: restart
restart: ## Redémarre la stack
	$(COMPOSE) restart

.PHONY: ps
ps: ## État des services
	$(COMPOSE) ps

.PHONY: logs
logs: ## Suit les logs (make logs s=api pour un seul service)
	$(COMPOSE) logs -f --tail=100 $(s)

.PHONY: pull
pull: ## Récupère les dernières images publiées
	$(COMPOSE) pull

.PHONY: deploy
deploy: ## Met à jour les images et relance la stack
	$(COMPOSE) pull
	$(COMPOSE) up -d --remove-orphans
	$(COMPOSE) ps

.PHONY: config
config: ## Vérifie et affiche la configuration compose résolue
	$(COMPOSE) config

.PHONY: nginx-test
nginx-test: ## Vérifie la syntaxe de la configuration nginx
	$(COMPOSE) exec nginx nginx -t

.PHONY: nginx-reload
nginx-reload: nginx-test ## Recharge nginx sans couper les connexions
	$(COMPOSE) exec nginx nginx -s reload

.PHONY: backup
backup: ## Déclenche une sauvegarde immédiate
	$(COMPOSE) run --rm backup once

.PHONY: backups
backups: ## Liste les sauvegardes disponibles
	@ls -lh backups/ 2>/dev/null || echo "aucune sauvegarde"

.PHONY: shell
shell: ## Ouvre un shell dans le conteneur de sauvegarde (outils sqlite3/psql)
	$(COMPOSE) run --rm --entrypoint sh backup
