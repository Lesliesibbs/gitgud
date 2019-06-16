defmodule GitGud.GitCommit do
  @moduledoc """
  Git commit schema and helper functions.
  """
  use Ecto.Schema

  alias GitRekt.Git

  alias GitGud.DB
  alias GitGud.Repo

  @primary_key false
  schema "git_commits" do
    belongs_to :repo, Repo, primary_key: true
    field :oid, :binary, primary_key: true
    field :parents, {:array, :binary}
    field :message, :string
    field :author_name, :string
    field :author_email, :string
    field :gpg_key_id, :binary
    field :committed_at, :naive_datetime
  end

  @type t :: %__MODULE__{
    repo_id: pos_integer,
    repo: Repo.t,
    oid: Git.oid,
    parents: [Git.oid],
    message: binary,
    author_name: binary,
    author_email: binary,
    gpg_key_id: binary,
    committed_at: NaiveDateTime.t
  }

  @doc """
  Decodes the given *RAW* commit `data`.
  """
  @spec decode(binary) :: map
  def decode(data) do
    commit = extract_commit_props(data)
    author = extract_commit_author(commit)
    %{
      parents: extract_commit_parents(commit),
      message: commit["message"],
      author_name: author["name"],
      author_email: author["email"],
      gpg_key_id: extract_commit_gpg_key_id(commit),
      committed_at: author["time"],
    }
  end

  @doc """
  Returns the number of ancestors for the given `repo_id` and commit `oid`.
  """
  @spec count_ancestors(pos_integer, Git.oid) :: {:ok, pos_integer} | {:error, term}
  def count_ancestors(repo_id, oid) do
    case Ecto.Adapters.SQL.query!(DB, "SELECT COUNT(*) FROM git_commits_dag($1, $2)", [repo_id, oid]) do
      %Postgrex.Result{rows: [[count]]} -> {:ok, count}
    end
  end

  @doc """
  Returns the number of ancestors for the given `commit`.
  """
  @spec count_ancestors(t) :: {:ok, pos_integer} | {:error, term}
  def count_ancestors(%__MODULE__{repo_id: repo_id, oid: oid} = _commit) do
    count_ancestors(repo_id, oid)
  end

  #
  # Helpers
  #

  defp extract_commit_props(data) do
    [header, message] = String.split(data, "\n\n", parts: 2)
    header
    |> String.split("\n", trim: true)
    |> Enum.chunk_by(&String.starts_with?(&1, " "))
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [one] -> one
      [one, two] ->
        two = Enum.join(Enum.map(two, &String.trim_leading/1), "\n")
        List.update_at(one, -1, &Enum.join([&1, two], "\n"))
    end)
    |> Enum.map(fn line ->
      [key, val] = String.split(line, " ", parts: 2)
      {key, String.trim_trailing(val)}
    end)
    |> List.insert_at(0, {"message", message})
    |> Enum.reduce(%{}, fn {key, val}, acc -> Map.update(acc, key, val, &(List.wrap(val) ++ [&1])) end)
  end

  defp extract_commit_parents(commit) do
    Enum.map(List.wrap(commit["parent"] || []), &Git.oid_parse/1)
  end

  defp extract_commit_author(commit) do
    ~r/^(?<name>.+) <(?<email>.+)> (?<time>[0-9]+) (?<time_offset>[-\+][0-9]{4})$/
    |> Regex.named_captures(commit["author"])
    |> Map.update!("time", &DateTime.to_naive(DateTime.from_unix!(String.to_integer(&1))))
  end

  defp extract_commit_gpg_key_id(commit) do
    if gpg_signature = commit["gpgsig"] do
      {_checksum, lines} =
        gpg_signature
        |> String.split("\n")
        |> List.delete_at(0)
        |> List.delete_at(-1)
        |> Enum.drop_while(&(&1 != ""))
        |> List.delete_at(0)
        |> List.pop_at(-1)

      lines
      |> Enum.join()
      |> Base.decode64!()
      |> binary_part(24, 8)
    end
  end
end
