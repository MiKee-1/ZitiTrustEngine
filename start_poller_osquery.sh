for g in gateway-a gateway-b; do
  docker compose exec -d $g gateway-poller poller.py
  docker compose exec -d $g bash osqueryd.sh
done