defmodule AiInPracticeWeb.ReportComponents do
  @moduledoc """
  Report content on screen: the blocks of `AiInPractice.Reports.Content`,
  shared by the reports screen and the check page, so a checked report reads
  as it did when it was written.
  """
  use Phoenix.Component

  @doc "Renders a list of report blocks."
  attr :blocks, :list, required: true

  def blocks(assigns) do
    ~H"""
    <%= for block <- @blocks do %>
      <%= case block do %>
        <% {:h2, text} -> %>
          <h3>{text}</h3>
        <% {:h3, text} -> %>
          <h4>{text}</h4>
        <% {:p, text} -> %>
          <p>{text}</p>
        <% {:strong, text} -> %>
          <p><strong>{text}</strong></p>
        <% {:statement, text} -> %>
          <p class="statement"><strong>{text}</strong></p>
        <% {:quote, text} -> %>
          <blockquote>{text}</blockquote>
        <% {:labelled, label, text} -> %>
          <p class="labelled"><span class="mono quiet">{label}</span><br />{text}</p>
        <% {:list, items} -> %>
          <ul>
            <li :for={item <- items}>{item}</li>
          </ul>
        <% {:reading, item} -> %>
          <div class="resource">
            <p>
              <strong :if={!item.url}>{item.title}</strong>
              <a :if={item.url} href={item.url} rel="noreferrer noopener" target="_blank">
                <strong>{item.title}</strong>
              </a>
              <span :if={item.meta} class="mono quiet resource-meta"><br />{item.meta}</span>
            </p>
            <p :if={item.why} class="resource-why">{item.why}</p>
            <p :if={item.note} class="quiet">{item.note}</p>
          </div>
      <% end %>
    <% end %>
    """
  end
end
