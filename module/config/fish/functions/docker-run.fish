function docker-run --description "Run the docker container"
    if test (count $argv) -gt 0
        set SCRIPT_DIR $argv[1]
    else
        set SCRIPT_DIR (pwd)
    end

    if not docker system prune -f
        echo "Docker system prune failed."
        return 1
    end

    if not $SCRIPT_DIR/run.sh
        echo "Run failed."
        return 1
    end
end
