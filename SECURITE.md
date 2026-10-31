# Rapport securite NovaSphere

## Contrainte d'environnement

Le compte utilise est un AWS Academy Learner Lab. La creation de roles et de
politiques IAM y est interdite. Les etapes de S05 portant sur l'ecriture d'un
role au moindre privilege sont donc realisees en consommant le role fourni
`LabRole` via son profil `LabInstanceProfile`, lu avec un bloc `data`. Le
controle « aucune politique creee avec Resource = "*" » n'est pas verifiable
dans ce cadre : aucune politique n'est creee par ce code.

## Etape 1 — Les fuites constatees (version naive)

Secret utilise pour la demonstration : `NovaSphere2026Secret`.

1. **Le code.** `git grep NovaSphere2026Secret` le trouve dans
   `infra/envs/dev/variables.tf`, en valeur par defaut d'une variable.
   Une fois commite, il reste dans l'historique Git indefiniment.

2. **Le state.** `terraform state pull | grep` ne renvoie rien, ce qui est
   trompeur : le `user_data` y est stocke encode en base64. Apres decodage,
   le mot de passe apparait en clair. `sensitive = true` masque la valeur
   dans la sortie console, jamais dans le fichier de state — qui vit dans un
   bucket S3 partage par l'equipe. Base64 est un encodage, pas un chiffrement.

3. **Le user_data.** Toute identite disposant de `ec2:DescribeInstanceAttribute`
   peut lire le script d'amorcage d'une instance en cours d'execution :
   `aws ec2 describe-instance-attribute --attribute userData | base64 -d`.
   Le mot de passe y etait en clair.

## Etape 2 — Le secret ne transite plus par Terraform

Le mot de passe est stocke dans Parameter Store en `SecureString`, ecrit avec
l'argument en ecriture seule `value_wo`, accompagne de `value_wo_version` —
obligatoire, puisque c'est lui qui declenche une reecriture : Terraform ne peut
pas comparer une valeur qu'il ne conserve pas. La variable est marquee
`ephemeral = true` : Terraform refuse de la persister. Sa valeur est fournie par
la variable d'environnement `TF_VAR_db_password`, jamais par un tfvars commite.

Verifications :
- `terraform state pull | grep -c '<valeur>'` renvoie 0
- le `user_data` decode depuis le state ne contient que l'appel `aws ssm get-parameter`
- `checkov` valide CKV_AWS_46 « no hard-coded secrets exist in EC2 user data »

## Etape 3 — Lecture par l'instance

L'instance lit le parametre au demarrage via le profil d'instance attache au
Launch Template. `bootstrap.sh` commence par `set -e` : un echec de lecture
arreterait le script avant `systemctl enable --now nginx`, la cible resterait
`unhealthy` et l'ALB ne servirait rien. Une cible `healthy` dans le target group
prouve donc que la lecture dechiffree a reussi.

Le Launch Template exige IMDSv2 (`http_tokens = "required"`) : les credentials
temporaires du role ne sont accessibles qu'apres obtention d'un jeton de session,
ce qui ferme la classe d'attaques par SSRF sur le service de metadonnees.

## Etape 4 — Scan statique (checkov)

Resultat apres corrections : 24 controles passes, 12 echoues, 2 ignores avec
justification.

Corriges :
- **CKV_AWS_23** — description ajoutee sur les regles de sortie des deux
  Security Groups. Une regle sans description est illisible en audit.
- **CKV_AWS_131** — `drop_invalid_header_fields = true` sur l'ALB : les en-tetes
  HTTP malformes sont rejetes au lieu d'etre transmis aux instances.

Assume et documente :
- **CKV_AWS_382** (sortie vers 0.0.0.0/0) — necessaire pour `apt` et pour
  l'appel a l'API SSM au demarrage. Le module ecarte volontairement la NAT
  Gateway (~0,05 $/h) : les instances sont en subnets publics et sortent par la
  passerelle Internet, protegees en entree par leurs Security Groups. Annote
  `#checkov:skip` sur les deux ressources.

Non corriges, hors perimetre pedagogique : HTTPS/TLS sur l'ALB (CKV_AWS_2,
CKV_AWS_103, CKV2_AWS_20, CKV_AWS_378) faute de nom de domaine et de certificat
ACM ; WAF (CKV2_AWS_28) ; logs d'acces de l'ALB (CKV_AWS_91) ; protection contre
la suppression (CKV_AWS_150), volontairement desactivee puisque la regle du
module impose un `destroy` en fin de seance.

## S06 — Derive detectee et tranchee

Une regle `tcp/8080` ouverte a `0.0.0.0/0` a ete ajoutee a la main sur le
Security Group des instances. `terraform plan` l'a signalee sous
« Objects have changed outside of Terraform ». Decision : **le code a raison**.
La regle n'avait fait l'objet d'aucune revue, exposait un port applicatif a
Internet entier, et contredit le modele de S04 ou les instances n'acceptent de
trafic que depuis le Security Group de l'ALB. `terraform apply` a remis la
realite en conformite. La remediation inverse, `terraform apply -refresh-only`,
aurait enterine la regle dans le state sans la soumettre a revue.

## S07 — Authentification de la CI : l'ecart assume

Le support impose OIDC : GitHub emet un jeton signe a chaque execution, AWS le
verifie et delivre des credentials temporaires pour un role IAM restreint a un
depot et une branche. Aucun secret n'est stocke, rien a faire tourner.

Ce dispositif exige deux ressources IAM : un `aws_iam_openid_connect_provider`
et un `aws_iam_role` portant une politique de confiance conditionnee sur les
claims `aud` et `sub` du jeton. Le compte AWS Academy Learner Lab interdit la
creation de l'un comme de l'autre.

Repli mis en place : les credentials temporaires de la session de lab sont
stockes dans les secrets du depot (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN`). C'est exactement la « solution naive » que le support
critique. Ses defauts, dans ce contexte precis :

- quiconque obtient un acces en ecriture aux secrets obtient les droits AWS ;
- la rotation est manuelle — ici elle est meme subie, les credentials du lab
  expirant a chaque session, ce qui casse le pipeline tant qu'ils ne sont pas
  recolles ;
- aucune restriction par depot ni par branche n'est possible : le jeton vaut
  pour tout ce que le role `voclabs` sait faire.

Sur un compte AWS standard, le passage a OIDC ne demanderait aucun changement
dans les workflows en dehors du remplacement du bloc `env` par l'action
`aws-actions/configure-aws-credentials` avec `role-to-assume`, et l'ajout de
la permission `id-token: write` deja presente en commentaire dans
`terraform-pr.yml`.
