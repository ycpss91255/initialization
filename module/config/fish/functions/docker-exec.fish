function docker-exec --description "Execute docker container" \
    --wraps "docker exec" \
    --argument-names _container
    # If no container is specified, get the first running container
    test -z "$_container"; or set -l _container (docker ps -q | head -n 1)

    # Check if the container is running
    if test -z "$_container"
        printf "No running container found\n"
        return 1
    end

    docker exec -it "$_container" /usr/bin/env bash
end

