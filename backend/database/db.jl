module Database

using LibPQ

function connect_db()

    host = get(ENV, "DB_HOST", "127.0.0.1")
    port = get(ENV, "DB_PORT", "5432")
    dbname = get(ENV, "DB_NAME", "msl_db")
    user = get(ENV, "DB_USER", "msl_user")
    password = get(ENV, "DB_PASSWORD", "msl_password")

    conn_string = """
    host=$host
    port=$port
    dbname=$dbname
    user=$user
    password=$password
    """

    try

        conn = LibPQ.Connection(conn_string)

        println(
            "PostgreSQL conectado correctamente " *
            "($host:$port/$dbname)"
        )

        return conn

    catch e

        println("==============================================")
        println("ERROR DE CONEXIÓN CON POSTGRESQL")
        println("==============================================")
        println("Host: $host")
        println("Puerto: $port")
        println("Base de datos: $dbname")
        println("Usuario: $user")
        println("")
        println("Error:")
        println(sprint(showerror, e))
        println("==============================================")

        error(
            "No fue posible conectar con PostgreSQL. " *
            "Verifica que el servidor esté iniciado."
        )

    end
end

end