defmodule ShopifexWeb.AuthController do
  @moduledoc """
  You can use this module inside of another controller to handle initial iFrame load and shop installation

  Example:

  ```elixir
  defmodule MyAppWeb.AuthController do
    use MyAppWeb, :controller
    use ShopifexWeb.AuthController

    # Thats it! Validation, installation are now handled for you :)
  end
  ```
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour ShopifexWeb.AuthController.Behaviour
      require Logger

      # get authorization token for the shop and save the shop in the DB
      def auth(conn, %{"shop" => shop_url}) do
        if Regex.match?(~r/^.*\.myshopify\.com/, shop_url) do
          conn = put_flash(conn, :shop_url, shop_url)
          # check if store is in the system already:
          case Shopifex.Shops.get_shop_by_url(shop_url) do
            nil ->
              install_url =
                "https://#{shop_url}/admin/oauth/authorize?client_id=#{
                  Application.fetch_env!(:shopifex, :api_key)
                }&scope=#{Application.fetch_env!(:shopifex, :scopes)}&redirect_uri=#{
                  Application.fetch_env!(:shopifex, :redirect_uri)
                }"

              conn
              |> redirect(external: install_url)

            shop ->
              if conn.private.valid_hmac do
                conn
                |> put_flash(:shop, shop)
                |> before_render(shop)
              else
                send_resp(
                  conn,
                  403,
                  "A store was found, but no valid HMAC parameter was provided. Please load this app within the #{
                    shop_url
                  } admin panel."
                )
              end
          end
        else
          conn
          |> put_view(ShopifexWeb.AuthView)
          |> put_layout({ShopifexWeb.LayoutView, "app.html"})
          |> put_flash(:error, "Invalid shop URL")
          |> render("select-store.html")
        end
      end

      def auth(conn, _) do
        conn
        |> put_view(ShopifexWeb.AuthView)
        |> put_layout({ShopifexWeb.LayoutView, "app.html"})
        |> render("select-store.html")
      end

      @doc """
      Optional callback executed after a request has been validated and the store has been loaded into the session.
      Here you can do something like make sure the store's subscription is in order before rendering the app.
      """
      def before_render(conn, shop), do: redirect(conn, to: "/")

      def install(conn = %{private: %{valid_hmac: true}}, %{"code" => code, "shop" => shop_url}) do
        url = "https://#{shop_url}/admin/oauth/access_token"

        case(
          HTTPoison.post(
            url,
            Jason.encode!(%{
              client_id: Application.fetch_env!(:shopifex, :api_key),
              client_secret: Application.fetch_env!(:shopifex, :secret),
              code: code
            }),
            "Content-Type": "application/json",
            Accept: "application/json"
          )
        ) do
          {:ok, response} ->
            shop =
              Jason.decode!(response.body, keys: :atoms)
              |> Map.put(:url, shop_url)
              |> Shopifex.Shops.create_shop()
              |> Shopifex.Shops.configure_webhooks()

            after_install(conn, shop)

          error ->
            IO.inspect(error)
        end
      end

      @doc """
      Optional callback executed after a store has been stored in the database and the webhooks have been configured.
      """
      def after_install(conn, shop),
        do:
          redirect(conn,
            external:
              "https://#{shop.url}/admin/apps/#{Application.fetch_env!(:shopifex, :api_key)}"
          )

      defoverridable ShopifexWeb.AuthController.Behaviour
    end
  end

  defmodule Behaviour do
    @callback before_render(conn :: %Plug.Conn{}, shop :: struct()) :: Plug.Conn
    @callback after_install(conn :: %Plug.Conn{}, shop :: struct()) :: Plug.Conn
    @optional_callbacks before_render: 2, after_install: 2
  end
end
