class ScriptText < ActiveRecord::Base
  attr_accessible :section, :script_id, :script_order

  validates :section, presence: true
  validates :script, presence: true
  validates :script_order, presence: true, numericality: true

  belongs_to :script
end
