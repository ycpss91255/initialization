function docker-build-run --description "Build and run the docker container"
    if test (count $argv) -gt 0
        set _script_dir $argv[1]
    else
        set _script_dir (pwd)
    end

    if not docker system prune -f
        echo "Docker system prune failed."
        return 1
    end

    if not $_script_dir/build.sh
        echo "Build failed."
        return 1
    end

    clear

    if not $_script_dir/run.sh
        echo "Run failed."
        return 1
    end
end
