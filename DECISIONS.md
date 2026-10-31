# Decisions d'architecture — NovaSphere

Chaque entree donne le choix retenu, la raison, ce qui a ete ecarte et ce que
cela coute.

## 1. Un repertoire par environnement, pas un workspace

Retenu : `infra/envs/dev` et `infra/envs/prod`, chacun avec son bloc `backend`,
sa cle de state et son `env.auto.tfvars`.

Ecarte : les workspaces Terraform.

Raison : avec un workspace, l'environnement courant est un etat invisible du
terminal. `terraform destroy` est la meme commande en dev et en prod ; seule
une commande tapee auparavant decide de la cible. Avec des repertoires, trois
signaux independants nomment la cible avant la confirmation : le chemin
courant, la cle du backend, et le nom des ressources dans le plan. Les deux
environnements peuvent en outre recevoir des droits et des versions de module
differents.

Cout : les deux `main.tf` sont identiques. Acceptable, puisque toute la logique
vit dans les modules et que les environnements se contentent de les appeler.
Le `diff` entre les deux repertoires est d'ailleurs la file d'attente de
promotion, lisible a tout instant.

## 2. Verrouillage natif S3, pas de table DynamoDB

Retenu : `use_lockfile = true` sur le backend S3.

Ecarte : `dynamodb_table`.

Raison : l'argument DynamoDB est deprecie par HashiCorp. Le verrouillage natif
repose sur les ecritures conditionnelles S3 : deux ecritures simultanees du
fichier `.tflock`, une reussit, l'autre recoit un code 412. Une ressource de
moins a creer, a payer et a surveiller.

## 3. Pas de NAT Gateway

Retenu : instances dans les subnets publics, avec IP publique, protegees en
entree par leurs Security Groups.

Ecarte : subnets prives derriere une NAT Gateway.

Raison : une NAT Gateway coute environ 0,05 $ par heure plus le trafic, soit le
premier poste de depense d'une infrastructure de ce type. Les instances ont
besoin de sortir (apt, API SSM) mais pas d'etre joignables. Leur Security Group
n'accepte aucune connexion depuis Internet : la protection vient de la regle,
pas de la topologie.

Cout : une erreur de Security Group exposerait directement les instances. En
production reelle avec budget, les subnets prives seraient le choix par defaut.

## 4. VPC depuis le registre, pile web en module maison

Retenu : `terraform-aws-modules/vpc/aws` pour le reseau,
`terraform-aws-web-stack` ecrit par l'equipe pour l'ALB, le Launch Template et
l'auto-scaling.

Raison : un VPC complet represente une trentaine de ressources (subnets, tables
de routage, passerelle, associations) sans aucune specificite NovaSphere.
L'ecrire serait reecrire une brique standard. La pile web, elle, porte les
choix propres au projet — chainage des Security Groups, exigence IMDSv2, taille
du groupe d'auto-scaling — et doit donc vivre dans un module a nous, versionne
par tag Git.

## 5. Parameter Store, pas Secrets Manager

Retenu : parametre SSM de type `SecureString`, chiffre par KMS.

Ecarte : AWS Secrets Manager.

Raison : Secrets Manager apporte la rotation automatique et le versionnement,
pour environ 0,40 $ par secret et par mois. La rotation n'est pas une exigence
du projet. Parameter Store couvre le besoin au niveau standard, gratuitement,
et le principe de lecture est identique : l'instance lit le secret au demarrage
grace a son role.

## 6. Le secret ne transite jamais par Terraform

Retenu : variable `ephemeral = true`, ecriture via `value_wo` et
`value_wo_version`, valeur fournie par `TF_VAR_db_password`.

Ecarte : une variable ordinaire marquee `sensitive`.

Raison : `sensitive` masque la valeur dans la sortie console, jamais dans le
fichier de state — qui vit dans un bucket partage par l'equipe. Les arguments
en ecriture seule envoient la valeur a AWS sans que Terraform la conserve, ni
dans le plan ni dans le state. `value_wo_version` est obligatoire : c'est lui
qui declenche une reecriture, puisque Terraform ne peut pas comparer une valeur
qu'il ne garde pas.

Verification : `terraform state pull | grep` ne trouve rien, et le `user_data`
decode depuis le state ne contient que l'appel `aws ssm get-parameter`.

## 7. Aucun acces SSH, configuration au demarrage

Retenu : amorcage par `user_data`, moins de dix lignes, qui installe nginx et
lit le secret depuis Parameter Store.

Ecarte : Ansible au demarrage (`ansible-pull`) ou via SSM Run Command.

Raison : les instances sont creees et detruites en continu par l'auto-scaling ;
un inventaire statique perime a chaque remplacement. Supprimer la regle SSH
supprime du meme coup la gestion des cles et une surface d'attaque entiere.
Le cahier des charges classe Ansible au demarrage en bonus, pas en exigence.

Cout : plus de debogage interactif sur une instance. Un bastion ou SSM Session
Manager serait la reponse si le besoin apparaissait. Le repertoire `ansible/`
est conserve pour memoire mais n'est plus utilise.

## 8. IMDSv2 exige

Retenu : `http_tokens = "required"` sur le Launch Template.

Raison : les credentials temporaires du role d'instance sont servis par le
service de metadonnees. En IMDSv1 une simple requete suffit, ce qui rend toute
faille de type SSRF dans l'application suffisante pour les exfiltrer. IMDSv2
impose d'obtenir d'abord un jeton de session par une requete PUT, que les
attaques SSRF classiques ne savent pas emettre.

## 9. Security Groups chaines par reference

Retenu : le Security Group des instances autorise le port 80 depuis
`aws_security_group.alb.id`, pas depuis une plage d'adresses.

Raison : les instances sont remplacees en permanence et changent d'IP. Une
regle par CIDR serait invalide des le premier remplacement. L'appartenance a un
groupe, elle, reste vraie. Consequence verifiable : aucune regle d'entree des
instances ne mentionne Internet.

## 10. create_before_destroy et name_prefix sur les Security Groups

Retenu : les deux ensemble.

Raison : par defaut, Terraform detruit avant de recreer. Un Security Group
attache a une instance en cours d'execution ne peut pas etre supprime : AWS
repond `DependencyViolation` et Terraform boucle jusqu'a expiration. En
inversant l'ordre, le nouveau groupe est cree et attache avant la suppression
de l'ancien. `name_prefix` devient alors obligatoire : les deux versions
coexistent un instant et ne peuvent pas porter le meme nom.

## 11. Authentification de la CI : ecart subi

Retenu par defaut : credentials stockes dans les secrets du depot.

Voulu : OIDC, sans aucun secret stocke.

Raison de l'ecart : OIDC exige de creer un `aws_iam_openid_connect_provider` et
un `aws_iam_role`. Le compte AWS Academy Learner Lab interdit la creation de
ressources IAM. Le detail de l'ecart et de ses consequences est dans
`SECURITE.md`. Sur un compte standard, le passage a OIDC ne changerait que le
bloc d'authentification des workflows.

## 12. Role d'instance : `LabRole` au lieu d'un role au moindre privilege

Retenu par defaut : `LabInstanceProfile`, lu par un bloc `data`.

Voulu : un role dedie n'autorisant que `ssm:GetParameter` sur
`/novasphere/<environnement>/*`.

Raison de l'ecart : meme contrainte IAM. Consequence : le controle « aucune
politique creee avec `Resource = "*"` » n'est pas verifiable, puisque ce code
ne cree aucune politique. `LabRole` est beaucoup plus large que necessaire.

## 13. Depot miroir sur GitHub

Retenu : le depot de travail vit sur GitLab, un miroir sur GitHub porte la
chaine de livraison.

Raison : le module impose GitHub Actions, son modele de permissions de jeton,
ses environnements proteges et son OIDC. Transposer vers GitLab CI aurait
conserve les concepts mais change toute la syntaxe, et aurait rendu le travail
incomparable a celui du reste de la classe. Le depot du module
`terraform-aws-web-stack` est public, pour que les runners puissent le tirer en
HTTPS sans clef.
