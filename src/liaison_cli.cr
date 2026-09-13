require "./liaison_cli/config"
require "./liaison_cli/sessions"
require "./liaison_cli/commands/start"
require "./liaison_cli/commands/continue"
require "./liaison_cli/commands/list"
require "./liaison_cli/commands/show"
require "./liaison_cli/commands/delete"
require "./liaison_cli/commands/prune"

USAGE = <<-USAGE
  liaison — a portable session history

  Usage:
    liaison start <deployment> <prompt...> [--id <session-id>]
    liaison continue <session-id> <prompt...> [--on <deployment>]
    liaison list
    liaison show <session-id> [--snapshots] [--json]
    liaison prune <session-id> --keep <n>
    liaison delete <session-id>

  Deployments and their defaults come from ./liaison.yaml or ~/liaison.yaml.
  Sessions are stored under ./.liaison (if present) or ~/.liaison.
  USAGE

verb = ARGV[0]?
rest = ARGV[1..]? || [] of String

begin
  case verb
  when "start"
    Liaison::Cli::Commands::Start.run(rest)
  when "continue"
    Liaison::Cli::Commands::Continue.run(rest)
  when "list"
    Liaison::Cli::Commands::List.run(rest)
  when "show"
    Liaison::Cli::Commands::Show.run(rest)
  when "prune"
    Liaison::Cli::Commands::Prune.run(rest)
  when "delete"
    Liaison::Cli::Commands::Delete.run(rest)
  when nil, "-h", "--help"
    puts USAGE
  else
    STDERR.puts "unknown command: #{verb}"
    STDERR.puts USAGE
    exit 1
  end
rescue e : Liaison::Cli::ConfigError | Liaison::Cli::SessionError | ArgumentError
  STDERR.puts "liaison: #{e.message}"
  exit 1
rescue e : Liaison::TransportError
  STDERR.puts "liaison: #{e.message}"
  exit 1
end
