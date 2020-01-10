#! /usr/bin/env elixir

defmodule Workspace do
  @ignore [".git", ".", "..", ".DS_Store"]
  def list_files(path) do
    File.ls!(path)
    |> Enum.reject(&Enum.member?(@ignore, &1))
    |> Enum.map(&Path.expand/1)
  end

  def read_file(path) do
    File.read!(path)
  end
end

defmodule Blob do
  defstruct [:data, type: "blob"]

  def new(data) do
    %__MODULE__{data: data}
  end
end

defmodule Entry do
  defstruct [:name, :oid]

  def new(oid, name) do
    %Entry{name: name, oid: oid}
  end
end

defmodule Tree do
  @moduledoc """
  Git stores a tree for every directory in your app, including the root directory of your app.
  Meaning there is always at least one tree. The tree contains all of the things within that directory.
  If there are files, they are serialized to `Blobs`s, and the sha from that is put inside a file.
  Once all the blobs are added, the tree gets sha'd too. If there are sub directories, the trees for
  those directories are made first, then put into the tree of it's parent directory.

  Given:

  file.txt
  directory
    - other.txt

  We'd make a blob for `file.txt`, then a tree for `directory`, and put the shas for both of those
  into a file and sha that. That would be our tree. (The tree for `directory` would have  a blob for
  `other.txt` in it only.)
  """
  defstruct [:entries, mode: "100644"]
end

defprotocol Data do
  def serialize(data_type)
end

defimpl Data, for: Blob do
  def serialize(%Blob{data: data, type: type}) do
    null_byte = "\0"
    "#{type} #{byte_size(data)}#{null_byte}#{data}"
  end
end

defimpl Data, for: Tree do
  def serialize(%Tree{entries: entries, mode: mode}) do
    null_byte = "\0"

    data =
      Enum.sort(entries, fn %{name: name}, %{name: name_2} -> name <= name_2 end)
      |> Enum.map(fn %{name: name, oid: oid} -> "#{mode} " <> name <> oid end)
      |> Enum.join("")

    "tree #{byte_size(data)}#{null_byte}#{data}"
  end
end

defmodule Author do
  defstruct [:name, :email]
end

defmodule Commit do
  defstruct [:tree_oid, :author, :message]
end

defimpl Data, for: Commit do
  def serialize(%{tree_oid: tree_oid, author: %{name: name, email: email}, message: message}) do
    null_byte = "\0"
    author = "#{name} <#{email}> #{DateTime.to_unix(DateTime.utc_now())}"
    data = "tree #{tree_oid}\nauthor #{author}\ncommitter #{author}\n\n#{message}"
    "commit #{byte_size(data)}#{null_byte}" <> data
  end
end

defmodule Zlib do
  def deflate(data) do
    z = :zlib.open()
    # The last arg here is a level. Level 1 is best speed, 9 would be best compression
    # http://erlang.org/doc/man/zlib.html#deflateInit-2
    :ok = :zlib.deflateInit(z, 1)
    compressed = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    compressed
  end

  def inflate(data) do
    z = :zlib.open()
    :zlib.inflateInit(z)
    uncompressed = :zlib.inflate(z, data)
    :zlib.inflateEnd(z)
    :zlib.close(z)
    uncompressed
  end
end

defmodule Database do
  def store(data_type, destination) do
    content = Data.serialize(data_type)
    object_id = :crypto.hash(:sha, content) |> Base.encode16() |> String.downcase()
    write_object(object_id, content, destination)
    object_id
  end

  def write_object(id, data, destination) do
    object_path =
      destination
      |> Path.join(String.slice(id, 0..1))
      |> Path.join(String.slice(id, 2..-1))

    File.mkdir_p!(Path.dirname(object_path))
    temp_path = Path.join(Path.dirname(object_path), "tmp_obj_#{temp_name()}")
    File.open!(temp_path, [:write, :exclusive], &IO.binwrite(&1, Zlib.deflate(data)))

    # We write all the data to a tmp file then move it atomically so that
    # if some other process attempts to read the file, it wont see a partially-written blob
    File.rename(temp_path, object_path)
  end

  def temp_name() do
    min = String.to_integer("100000", 36)
    max = String.to_integer("ZZZZZZ", 36)

    (:rand.uniform(max - min) + min)
    |> Integer.to_string(36)
  end
end

defmodule Command do
  def run(["init", path]), do: create_git_directories(path)
  def run(["init"]), do: create_git_directories(File.cwd!())

  def run(["commit"]) do
    root_path = Path.expand(File.cwd!())
    git_path = root_path |> Path.join(".git")
    db_path = git_path |> Path.join("objects")

    tree_oid =
      Workspace.list_files(root_path)
      |> Enum.map(fn path ->
        path
        |> Workspace.read_file()
        |> Blob.new()
        |> Database.store(db_path)
        |> Entry.new(path)
      end)
      |> (fn entries -> %Tree{entries: entries} end).()
      |> Database.store(db_path)

    name = Map.get(System.get_env(), "GIT_AUTHOR_NAME", "")
    email = Map.get(System.get_env(), "GIT_AUTHOR_EMAIL", "")
    message = IO.read(:stdio, :line)

    author = %Author{name: name, email: email}
    commit = %Commit{tree_oid: tree_oid, author: author, message: message}
    commit_oid = Database.store(commit, db_path)

    git_path
    |> Path.join("HEAD")
    |> File.open!([:write], &IO.binwrite(&1, commit_oid))
  end

  def run(command) do
    IO.warn("ejit: '#{command}' is not an ejit command.")
    # Non 0 exit code to be a good boy scout
    System.stop(1)
  end

  def create_git_directories(path) do
    git_path = path |> Path.expand() |> Path.join(".git")

    with :ok <- File.mkdir_p(Path.join(git_path, "objects")),
         :ok <- File.mkdir_p(Path.join(git_path, "refs")) do
      IO.puts("Initialized empty eJit repository in #{git_path}")
      System.stop(0)
    else
      {:error, error} ->
        IO.warn("fatal: #{inspect(error)}")
        # Non 0 exit code to be a good boy scout
        System.stop(1)
    end
  end
end

Command.run(System.argv())
