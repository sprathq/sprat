defmodule Sprat.Workflow.Template do
  @moduledoc """
  Pure data shape for a workflow template (docs/spec-v1.md §5): an ordered
  list of stages. "Which role runs a stage is data on the stage
  definition" (build brief, scope decisions) — `Sprat.Orchestrator` never
  hardcodes a role; it reads `stage.role`. Adding PM/Analyst later is a
  change to `Sprat.Workflow.Idea`/`Opportunity`, not to the Orchestrator.
  """

  defmodule Stage do
    @moduledoc "One stage: who runs it, what it needs, what it must produce, and its gate."

    @enforce_keys [:id, :title, :role, :prompt, :required_inputs, :deliverables, :gate, :limits]
    defstruct [
      :id,
      :title,
      :role,
      :prompt,
      :required_inputs,
      :deliverables,
      :gate,
      :limits,
      executor: nil
    ]

    @type t :: %__MODULE__{
            id: atom(),
            title: String.t(),
            role: String.t(),
            prompt: String.t(),
            required_inputs: [atom()],
            deliverables: [atom()],
            gate: atom() | nil,
            limits: map(),
            executor: (map() -> :ok | {:error, term()}) | nil
          }
  end

  @enforce_keys [:id, :title, :stages]
  defstruct [:id, :title, :stages]

  @type t :: %__MODULE__{id: atom(), title: String.t(), stages: [Stage.t()]}

  @doc "Builds one stage. Raises on missing required keys (via `@enforce_keys`)."
  def stage(attrs), do: struct!(Stage, attrs)

  @doc "Builds a template. Raises if `stages` is empty or has duplicate ids."
  def new(attrs) do
    template = struct!(__MODULE__, attrs)

    if template.stages == [] do
      raise ArgumentError, "template #{template.id} has no stages"
    end

    ids = Enum.map(template.stages, & &1.id)

    if length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "template #{template.id} has duplicate stage ids: #{inspect(ids)}"
    end

    template
  end

  @doc "The first stage of a template."
  def first_stage(%__MODULE__{stages: [first | _]}), do: first

  @doc "The stage after `stage_id`, or `nil` if `stage_id` is the last stage."
  def stage_after(%__MODULE__{stages: stages}, stage_id) do
    stages
    |> Enum.drop_while(&(&1.id != stage_id))
    |> Enum.drop(1)
    |> case do
      [next | _] -> next
      [] -> nil
    end
  end

  @doc "Finds a stage by id, or `nil`."
  def find_stage(%__MODULE__{stages: stages}, stage_id),
    do: Enum.find(stages, &(&1.id == stage_id))
end
