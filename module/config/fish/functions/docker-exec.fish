function docker-exec --wraps "docker exec" --description "Execute docker container"
    if test (count $argv) -gt 0
        set _container $argv[1]
    else
        set _container (docker ps -q | head -n 1)
    end

    if test -z "$_container"
        echo "No running container found"
    else
        docker exec -it $_container /bin/bash
    end
end

