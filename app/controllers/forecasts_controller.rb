class ForecastsController < ApplicationController
  def index
    @address = params[:address].to_s.squish
    return if @address.empty?

    @forecast = ForecastService.new.call(@address)
  rescue ForecastService::InvalidAddress => e
    @error = e.message
    render :index, status: :unprocessable_entity
  rescue ForecastService::Error => e
    @error = e.message
    render :index, status: :service_unavailable
  end
end
