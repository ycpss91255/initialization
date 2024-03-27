function docker-exec --description "Execute docker container" --wraps docker
    set container (if count $argv > 0; echo $argv[1]; else; docker ps -q; end)
    docker exec -it $container /bin/bash
end
