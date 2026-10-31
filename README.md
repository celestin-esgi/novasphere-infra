# NovaSphere — infrastructure

Infrastructure de la plateforme NovaSphere sur AWS, en deux environnements
isoles, deployee par Terraform et livree par GitHub Actions.

## Architecture

    Internet
       |
    [ ALB ]  subnets publics, deux zones de disponibilite
       |
    [ target group ]  health check HTTP sur /
       |
    [ ASG ]  min 2, max 4, depuis un Launch Template
       |-- instance zone a
       '-- instance zone b

    VPC 10.0.0.0/16, passerelle Internet, pas de NAT Gateway.
    Les instances n'acceptent le port 80 que depuis le Security Group de l'ALB.
    Aucun acces SSH : la configuration se fait au demarrage.
    Le secret applicatif est lu dans Parameter Store par le profil d'instance.

| Brique | Origine |
|---|---|
| Reseau | module public `terraform-aws-modules/vpc/aws` `~> 6.0` |
| Pile web | module maison `terraform-aws-web-stack` `v1.0.0` |

## Prerequis

| Outil | Version minimale |
|---|---|
| Terraform | 1.14 (1.11 minimum pour les arguments en ecriture seule) |
| AWS CLI | 2.x |
| Git | 2.30 |

Region du module : `us-east-1`. Ne pas en changer : le compte AWS Academy
Learner Lab n'autorise que `us-east-1` et `us-west-2`.

## 1. Credentials

Le compte est un Learner Lab : les credentials sont temporaires et changent a
chaque session. Demarrer le lab, puis copier le bloc *AWS Details > AWS CLI*
dans `~/.aws/credentials` — les trois lignes, `aws_session_token` compris.

    aws sts get-caller-identity

Une erreur `AccessDenied` mentionnant la politique `voc-cancel-cred` signifie
que la session est expiree. Ne pas debugger : redemarrer le lab et recoller.

## 2. Bucket de state, une seule fois

Le bucket est cree hors Terraform, deliberement : il doit exister avant que
Terraform puisse y ecrire, et un `destroy` ne doit jamais pouvoir supprimer le
contenant du state.

    aws s3api create-bucket --bucket novasphere-tfstate-<trigramme> --region us-east-1
    aws s3api put-bucket-versioning --bucket novasphere-tfstate-<trigramme> \
      --versioning-configuration Status=Enabled

Puis reporter ce nom dans `infra/envs/dev/backend.tf` et
`infra/envs/prod/backend.tf`. Un bloc `backend` n'accepte pas de variable : la
valeur y est ecrite en dur.

Note : `--create-bucket-configuration LocationConstraint` est interdit en
`us-east-1`, qui est la region d'origine de S3 et sa valeur par defaut.

## 3. Deployer un environnement

Le seul secret n'est jamais dans un fichier : il est fourni par
l'environnement et Terraform ne le conserve nulle part.

    export TF_VAR_db_password='<le mot de passe applicatif>'

    cd infra/envs/dev      # ou infra/envs/prod
    terraform init
    terraform plan         # a lire integralement
    terraform apply

Les parametres de chaque environnement sont dans son `env.auto.tfvars`
(`owner`, `environment`, `instance_type`). Ce ne sont pas des secrets : ils
definissent l'environnement et sont versionnes.

## 4. Verifier

    terraform output alb_dns_name

Compter deux minutes que le health check passe au vert, puis :

    for i in 1 2 3 4; do curl -s http://$(terraform output -raw alb_dns_name) | grep -o 'ip-[0-9-]*'; done

Deux noms d'hote doivent alterner : l'ALB repartit sur les deux zones.

## 5. Detruire

Obligatoire en fin de journee. L'ALB est facture a l'heure.

    export TF_VAR_db_password='<le mot de passe applicatif>'
    cd infra/envs/dev  && terraform destroy
    cd ../prod         && terraform destroy

Le secret est redemande meme pour detruire : c'est la preuve que Terraform ne
le garde ni dans le state ni dans le plan.

## Chaine de livraison

| Declencheur | Ce qui se passe |
|---|---|
| Pull request | format, validite, plan de dev poste en commentaire |
| Merge sur `main` | `apply` sur dev, puis prod en attente d'approbation |
| Planifie, 03h00 UTC | `plan -detailed-exitcode` sur les deux environnements, echoue si derive |
| Manuel | meme detection de derive, a la demande |

Secrets du depot : `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN`, `TF_VAR_DB_PASSWORD`. Les trois premiers expirent avec la
session de lab et doivent etre recolles. Voir `SECURITE.md` pour l'ecart
assume par rapport a l'authentification OIDC exigee par le module.

## Structure

    infra/envs/dev        environnement de developpement
    infra/envs/prod       environnement de production
    ansible/              configuration (non utilisee par l'architecture actuelle)
    scripts/              arret et demarrage de fin de journee
    .github/workflows/    chaine de livraison
    CONTRIBUTING.md       conventions d'equipe
    SECURITE.md           registre de securite
    DECISIONS.md          decisions d'architecture
