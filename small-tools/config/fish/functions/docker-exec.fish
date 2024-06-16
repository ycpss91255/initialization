function docker-exec --wraps docker --description "Execute docker container"
    if test (count $argv) -gt 0
        set CONTAINER $argv[1]
    else
        set CONTAINER (docker ps -q | head -n 1)
    end

    if test -z "$CONTAINER"
        echo "No running container found"
    else
        docker exec -it $CONTAINER /bin/bash
    end
end

