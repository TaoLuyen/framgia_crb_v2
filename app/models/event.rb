class Event < ApplicationRecord
  include PublicActivity::Common
  include SharedMethods
  require "chatwork"

  # acts_as_paranoid

  after_create :send_notify, :push_event_to_google_calendar
  before_destroy :send_email_delete_no_repeat_event
  before_save :default_title, if: "title.blank?"
  after_update :update_event_on_google_calendar
  before_destroy :delete_event_on_google_calendar

  ATTRIBUTES_PARAMS = [:title, :description, :status, :color, :all_day,
    :repeat_type, :repeat_every, :user_id, :calendar_id, :start_date,
    :finish_date, :start_repeat, :end_repeat, :exception_type, :exception_time,
    attendees_attributes: [:id, :email, :_destroy, :user_id],
    repeat_ons_attributes: [:id, :days_of_week_id, :_destroy],
    notification_events_attributes: [:id, :notification_id, :_destroy]].freeze

  has_many :attendees, dependent: :destroy
  has_many :users, through: :attendees
  has_many :repeat_ons, dependent: :destroy
  has_many :days_of_weeks, through: :repeat_ons
  has_many :event_exceptions, class_name: Event.name, foreign_key: :parent_id,
    dependent: :destroy

  has_many :notification_events, dependent: :destroy
  has_many :notifications, through: :notification_events
  has_many :event_teams, dependent: :destroy
  has_many :teams, through: :event_teams

  belongs_to :calendar
  belongs_to :owner, class_name: User.name, foreign_key: :user_id
  belongs_to :event_parent, class_name: Event.name, foreign_key: :parent_id

  alias_attribute :parent, :event_parent

  validates :title, presence: true
  validates :calendar, presence: true
  validates :start_date, presence: true
  validates :finish_date, presence: true
  validate :valid_repeat_date, if: :is_repeat?
  validates_with OverlapTimeValidator, unless: "self.calendar.is_allow_overlap?"

  delegate :name, to: :owner, prefix: :owner, allow_nil: true
  delegate :name, :is_auto_push_to_google_calendar,
    to: :calendar, prefix: true, allow_nil: true

  enum exception_type: [:delete_only, :delete_all_follow, :edit_only,
    :edit_all_follow, :edit_all]
  enum repeat_type: [:daily, :weekly, :monthly, :yearly]

  accepts_nested_attributes_for :attendees, allow_destroy: true
  accepts_nested_attributes_for :notification_events, allow_destroy: true
  accepts_nested_attributes_for :repeat_ons, allow_destroy: true

  scope :in_calendars, ->(calendar_ids) do
    where("events.calendar_id IN (?)", calendar_ids)
  end
  scope :shared_with_user, ->(user) do
    if user.persisted?
      selected_columns = (Event.attribute_names - ["calendar_id"]).map! do |column|
        "events.#{column}"
      end.join(", ")

      select("#{selected_columns}, at.user_id as attendee_user_id, \n
        at.event_id as attendee_event_id, calendars.id as calendar_id")
        .joins("INNER JOIN attendees as at ON events.id = at.event_id")
        .joins("INNER JOIN calendars ON at.email = calendars.address")
        .where("at.user_id = ?", user.id)
    else
      Event.none
    end
  end
  scope :without_id, ->(id) do
    where("id != ? AND parent_id != ?", id, id) if id.present?
  end
  scope :no_repeats, ->{where repeat_type: nil}
  scope :has_exceptions, ->{where.not exception_type: nil}
  scope :exception_edits, ->id do
    where "parent_id = ? AND exception_type IN (?)", id, [2, 3]
  end
  scope :after_date, ->date{where "start_date > ?", date}
  scope :follow_pre_nearest, ->start_date do
    where "start_date < ? AND
      (exception_type = ? OR old_exception_type = ?)", start_date,
      Event.exception_types[:edit_all_follow],
      Event.exception_types[:edit_all_follow]
  end
  scope :not_delete_only, -> do
    where("exception_type IS NULL OR exception_type != ?", Event.exception_types[:delete_only])
  end
  scope :old_exception_type_not_null, ->{where.not old_exception_type: nil}
  scope :in_range, ->start_date, end_date do
    where "start_date >= ? AND finish_date <= ?", start_date, end_date
  end
  scope :old_exception_edit_all_follow, -> do
    where "old_exception_type = ?", Event.exception_types[:edit_all_follow]
  end
  scope :of_calendar, ->calendar_id do
    where "calendar_id = ?", calendar_id
  end

  class << self
    def event_exception_at_time exception_type, start_time, end_time
      find_by "exception_type IN (?) and exception_time >= ? and exception_time <= ?",
        exception_type, start_time, end_time
    end

    def find_with_exception exception_time
      find_by "exception_type IN (?) and exception_time = ?",
        [Event.exception_types[:delete_only],
        Event.exception_types[:delete_all_follow]], exception_time
    end

    def events_of_parent parent_id, start_date
      where "parent_id = ? AND end_repeat > ? AND exception_type NOT IN (?)",
        parent_id, start_date, [Event.exception_types[:delete_only],
        Event.exception_types[:delete_all_follow]]
    end
  end

  Event.repeat_types.keys.each do |repeat_type|
    define_method "repeat_#{repeat_type}?" do
      send "#{repeat_type}?"
    end
  end

  def parent?
    parent_id.blank?
  end

  def exist_repeat?
    is_repeat? || event_parent.present?
  end

  def is_repeat?
    repeat_type.present?
  end

  def old_exception_edit_all_follow?
    old_exception_type == Event.exception_types[:edit_all_follow]
  end

  def not_delete_only?
    exception_type.nil? || exception_type != Event.exception_types[:delete_only]
  end

  private

  def default_title
    title = I18n.t('calendars.events.no_title')
  end

  def send_notify
    if exception_type.nil?
      attendees.each do |attendee|
        argv = {event_id: id, user_id: attendee.user_id, current_user_id: user_id}
        EmailWorker.perform_async argv
      end
      return
    end

    return if !self.delete_only? || !self.delete_all_follow?
    return unless (parent = Event.find_by id: parent_id)
    parent.attendees.each do |attendee|
      argv = {
        user_id: attendee.user_id,
        event_title: title,
        event_start_date: start_date,
        event_finish_date: finish_date,
        event_exception_type: exception_type,
        action_type: :delete_event
      }
      EmailWorker.perform_async argv
    end
  end

  def send_email_delete_no_repeat_event
    attendees.each do |attendee|
      argv = {
        user_id: attendee.user_id,
        event_title: title,
        event_start_date: start_date,
        event_finish_date: finish_date,
        event_exception_type: nil,
        action_type: :delete_event
      }
      EmailWorker.perform_async argv
    end
  end

  def valid_repeat_date
    return if start_repeat.nil? || end_repeat.nil?
    return if start_repeat <= end_repeat.end_of_day
    errors.add(:start_repeat, I18n.t("events.warning.start_date_less_than_end_date"))
  end

  def push_event_to_google_calendar
    return if google_calendar_id.blank?
    return unless calendar_is_auto_push_to_google_calendar
    EventWorker.perform_async id, "insert"
  end

  def update_event_on_google_calendar
    return if google_calendar_id.blank?
    return unless calendar_is_auto_push_to_google_calendar
    EventWorker.perform_async id, "update"
  end

  def delete_event_on_google_calendar
    return if google_calendar_id.blank?
    return unless calendar_is_auto_push_to_google_calendar
    EventWorker.perform_async id, "delete"
  end
end

