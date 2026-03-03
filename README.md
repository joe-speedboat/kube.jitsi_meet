# Install Jitsi Meet on K3S Single Node

## Prereq
* wanip must be configured on this node
  other setups may work, but are not tested
* following ports must be open
  * 10000/udp (jvb)   
    `kubectl exec -n meet deploy/meet-jitsi-meet-jvb-0 -- printenv | grep JVB`
  * 443/tcp (traefik ingingress controller)
    
## Install
* Prepare config
```bash
URL=meeting.domain.tld
NS=meeting
WANIP="$(curl -s ifconfig.me)"
sed "s/__NS__/$NS/" ingress.yml > my_ingress.yml
sed -i "s/__URL__/$URL/" my_ingress.yml
sed "s/__WANIP__/$WANIP/" values.yml > my_values.yml

kubectl create namespace $NS
kubectl config set-context --current --namespace="$1"


# install
helm repo add jitsi https://jitsi-contrib.github.io/jitsi-helm/
helm install meet jitsi/jitsi-meet --set publicURL=https://$URL -f my_values.yml 

# if you need adjustment
helm upgrade --install meet jitsi/jitsi-meet -f my_values.yml 
