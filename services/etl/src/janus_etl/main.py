from janus_etl.config import get_settings
from janus_etl.db import health_check


def main() -> None:
    settings = get_settings()

    print("JANUS ETL")
    print("---------")
    print(f"Environment: {settings.janus_env}")
    print(f"Data root:   {settings.resolved_data_root}")
    print()

    result = health_check(settings)

    print("Database connection successful.")
    print(f"Database:       {result['database']}")
    print(f"Principal:      {result['db_principal']}")
    print(f"Application:    {result['application_name']}")
    print(f"System event:   {result['system_event_id']}")


if __name__ == "__main__":
    main()
