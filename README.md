# tout-pris-docker

Déploiement de la stack **Tout Pris** : le backend [`tout-pris-back`](https://github.com/Haelle/tout-pris-back)
(FastAPI), le front [`tout-pris-front`](https://github.com/Haelle/tout-pris-front) (SvelteKit statique),
la base de données et le reverse proxy nginx qui les expose.

Ce dépôt ne contient pas de code applicatif : uniquement les fichiers
d'infrastructure (Docker Compose, configuration nginx, sauvegardes).
