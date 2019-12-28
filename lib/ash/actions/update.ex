defmodule Ash.Actions.Update do
  alias Ash.Authorization.Authorizer
  alias Ash.Actions.ChangesetHelpers

  @spec run(Ash.api(), Ash.record(), Ash.action(), Ash.params()) ::
          {:ok, Ash.record()} | {:error, Ecto.Changeset.t()} | {:error, Ash.error()}
  def run(api, %resource{} = record, action, params) do
    if Keyword.get(params, :side_load, []) in [[], nil] do
      case prepare_update_params(api, record, params) do
        %Ecto.Changeset{valid?: true} = changeset ->
          user = Keyword.get(params, :user)

          with {:auth, :authorized} <-
                 {:auth, do_authorize(params, action, user, resource, changeset)},
               %Ecto.Changeset{valid?: true} = changeset <-
                 prepare_update_params(api, record, params),
               %Ecto.Changeset{valid?: true} = changeset <-
                 ChangesetHelpers.run_before_changes(changeset),
               {:ok, result} <- do_update(resource, changeset) do
            ChangesetHelpers.run_after_changes(changeset, result)
          else
            :forbidden -> {:error, :forbidden}
            {:error, error} -> {:error, error}
            %Ecto.Changeset{} = changeset -> {:error, changeset}
          end

        changeset ->
          {:error, changeset}
      end
    else
      {:error, "Cannot side load on update currently"}
    end
  end

  defp do_authorize(params, action, user, resource, changeset) do
    if params[:authorization] do
      auth_request =
        Ash.Authorization.Request.new(
          state_key: :data,
          resource: resource,
          authorization_steps: action.authorization_steps,
          changeset: changeset,
          source: "update action"
        )

      Authorizer.authorize(user, [auth_request])
    else
      :authorized
    end
  end

  defp do_update(resource, changeset) do
    if Ash.data_layer_can?(resource, :transact) do
      Ash.data_layer(resource).transaction(fn ->
        with %{valid?: true} = changeset <- ChangesetHelpers.run_before_changes(changeset),
             {:ok, result} <- Ash.DataLayer.create(resource, changeset) do
          ChangesetHelpers.run_after_changes(changeset, result)
        end
      end)
    else
      with %{valid?: true} = changeset <- ChangesetHelpers.run_before_changes(changeset),
           {:ok, result} <- Ash.DataLayer.create(resource, changeset) do
        ChangesetHelpers.run_after_changes(changeset, result)
      else
        %Ecto.Changeset{valid?: false} = changeset ->
          {:error, changeset}
      end
    end
  end

  defp prepare_update_params(api, %resource{} = record, params) do
    attributes = Keyword.get(params, :attributes, %{})
    relationships = Keyword.get(params, :relationships, %{})
    authorization = Keyword.get(params, :authorization, false)

    with %{valid?: true} = changeset <- prepare_update_attributes(record, attributes),
         changeset <- Map.put(changeset, :__ash_api__, api) do
      ChangesetHelpers.prepare_relationship_changes(
        changeset,
        resource,
        relationships,
        authorization
      )
    end
  end

  defp prepare_update_attributes(%resource{} = record, attributes) do
    allowed_keys =
      resource
      |> Ash.attributes()
      |> Enum.map(& &1.name)

    changeset =
      record
      |> Ecto.Changeset.cast(attributes, allowed_keys)
      |> Map.put(:action, :update)

    resource
    |> Ash.attributes()
    |> Enum.reject(&Map.get(&1, :allow_nil?))
    |> Enum.reduce(changeset, fn attr, changeset ->
      case Ecto.Changeset.fetch_change(changeset, attr.name) do
        {:ok, nil} ->
          Ecto.Changeset.add_error(changeset, attr.name, "must not be nil")

        _ ->
          changeset
      end
    end)
  end
end
