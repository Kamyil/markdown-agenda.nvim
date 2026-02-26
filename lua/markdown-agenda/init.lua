local M = {}

local defaults = {
  directory = '~/notes',
  recursive = true,
  date_format = '%Y-%m-%d',
  help = true,
  header_separator = true,
  help_separator = true,
  border = 'rounded',
  title = ' Agenda ',
  title_pos = 'center',
  calendar = {
    enabled = true,
    months_to_show = 3,
    position = 'right',
    grid_columns = 2,
    week_start = 'monday',
  },
  icons = {
    scheduled = '📌',
    deadline_urgent = '🔴',
    deadline_soon = '🟡',
    deadline_ok = '🟢',
    overdue = '⚠️',
    today = '▶',
    collapsed = '▶',
    expanded = '▼',
  },
  keymaps = {
    open = '<leader>na',
  },
}

local config = {}

local state = {
  today_expanded = true,
  week_expanded = true,
}

local DAY_SECONDS = 24 * 60 * 60
local format_task_line
local pad_to_display_width

local function is_help_enabled()
  return config.help == true
end

local function is_header_separator_enabled()
  return config.header_separator == true
end

local function is_help_separator_enabled()
  return config.help_separator == true
end

local function get_window_border()
  if type(config.border) == 'string' or type(config.border) == 'table' then
    return config.border
  end

  return defaults.border
end

local function get_window_title()
  if config.title == false then
    return nil
  end

  if type(config.title) == 'string' then
    return config.title
  end

  return defaults.title
end

local function get_window_title_pos()
  local value = config.title_pos
  if value == 'left' or value == 'center' or value == 'right' then
    return value
  end

  return defaults.title_pos
end

local function start_of_day(timestamp)
  return os.time({
    year = tonumber(os.date('%Y', timestamp)),
    month = tonumber(os.date('%m', timestamp)),
    day = tonumber(os.date('%d', timestamp)),
  })
end

local function get_today_timestamp()
  return start_of_day(os.time())
end

local function parse_date(date_str, format)
  if format == '%Y-%m-%d' then
    local year, month, day = date_str:match('(%d%d%d%d)%-(%d%d)%-(%d%d)')
    if year and month and day then
      return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day) })
    end
  elseif format == '%m/%d/%Y' then
    local month, day, year = date_str:match('(%d%d)/(%d%d)/(%d%d%d%d)')
    if year and month and day then
      return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day) })
    end
  elseif format == '%d/%m/%Y' then
    local day, month, year = date_str:match('(%d%d)/(%d%d)/(%d%d%d%d)')
    if year and month and day then
      return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day) })
    end
  end
  return nil
end

local function get_date_pattern(format)
  if format == '%Y-%m-%d' then
    return '%d%d%d%d%-%d%d%-%d%d'
  elseif format == '%m/%d/%Y' or format == '%d/%m/%Y' then
    return '%d%d/%d%d/%d%d%d%d'
  end
  return '%d%d%d%d%-%d%d%-%d%d'
end

local function format_date(timestamp)
  return os.date(config.date_format, timestamp)
end

local function format_display_date(timestamp, today)
  local diff_days = math.floor((timestamp - today) / DAY_SECONDS)
  local weekday = os.date('%A', timestamp)
  local date_str = os.date(config.date_format, timestamp)

  if diff_days == 0 then
    return string.format('Today (%s, %s)', weekday, date_str)
  elseif diff_days == 1 then
    return string.format('Tomorrow (%s, %s)', weekday, date_str)
  elseif diff_days == -1 then
    return string.format('Yesterday (%s, %s)', weekday, date_str)
  elseif diff_days > 0 then
    return string.format('%s (%s) - in %d days', weekday, date_str, diff_days)
  else
    return string.format('%s (%s) - %d days ago', weekday, date_str, -diff_days)
  end
end

local function get_deadline_severity(deadline_ts, today)
  local days_left = math.floor((deadline_ts - today) / DAY_SECONDS)
  if days_left < 0 then
    return 'overdue', days_left
  elseif days_left <= 1 then
    return 'urgent', days_left
  elseif days_left <= 4 then
    return 'soon', days_left
  end

  return 'ok', days_left
end

local function deadline_icon_for_severity(severity)
  local icons = config.icons
  if severity == 'urgent' then
    return icons.deadline_urgent
  elseif severity == 'soon' then
    return icons.deadline_soon
  end

  return icons.deadline_ok
end

local function deadline_group_for_severity(severity)
  if severity == 'urgent' then
    return 'DiagnosticError'
  elseif severity == 'soon' then
    return 'DiagnosticWarn'
  elseif severity == 'ok' then
    if vim.fn.hlexists('DiagnosticOk') == 1 then
      return 'DiagnosticOk'
    end
    return 'DiagnosticHint'
  end

  return 'WarningMsg'
end

local function calendar_day_group(severity, is_today)
  if severity then
    return deadline_group_for_severity(severity)
  end

  if is_today then
    return 'DiagnosticInfo'
  end

  return nil
end

local function add_months(year, month, offset)
  local new_year = year
  local new_month = month + offset

  while new_month > 12 do
    new_month = new_month - 12
    new_year = new_year + 1
  end

  while new_month < 1 do
    new_month = new_month + 12
    new_year = new_year - 1
  end

  return new_year, new_month
end

local function normalize_week_start(value)
  if value == 'monday' then
    return 'monday'
  end

  return 'sunday'
end

local function get_weekday_header(week_start)
  if week_start == 'monday' then
    return 'Mo Tu We Th Fr Sa Su'
  end

  return 'Su Mo Tu We Th Fr Sa'
end

local function normalize_weekday_index(weekday, week_start)
  if week_start == 'monday' then
    return (weekday + 6) % 7
  end

  return weekday
end

local function build_deadline_map(tasks, today)
  local severity_rank = {
    ok = 1,
    soon = 2,
    urgent = 3,
    overdue = 4,
  }

  local deadline_map = {}
  for _, task in ipairs(tasks) do
    if task.date_type == 'deadline' or task.date_type == 'both' then
      local deadline_ts = task.deadline_ts or task.date
      local date_key = os.date('%Y-%m-%d', deadline_ts)
      local severity = get_deadline_severity(deadline_ts, today)
      local existing = deadline_map[date_key]

      if not existing or severity_rank[severity] > severity_rank[existing] then
        deadline_map[date_key] = severity
      end
    end
  end

  return deadline_map
end

local function build_calendar_month_block(year, month, today_key, deadline_map, week_start)
  local lines = {}
  local highlights = {}
  local month_start_ts = os.time({ year = year, month = month, day = 1 })
  local first_weekday = normalize_weekday_index(tonumber(os.date('%w', month_start_ts)), week_start)
  local days_in_month = tonumber(os.date('%d', os.time({ year = year, month = month + 1, day = 0 })))

  table.insert(lines, os.date('%B %Y', month_start_ts))
  table.insert(lines, get_weekday_header(week_start))

  local day = 1
  while day <= days_in_month do
    local cells = {}
    local cell_data = {}

    for display_weekday = 0, 6 do
      if (day == 1 and display_weekday < first_weekday) or day > days_in_month then
        table.insert(cells, '  ')
      else
        local day_text = string.format('%2d', day)
        local day_key = string.format('%04d-%02d-%02d', year, month, day)

        table.insert(cells, day_text)
        table.insert(cell_data, {
          weekday = display_weekday,
          day_key = day_key,
        })

        day = day + 1
      end
    end

    local week_line_idx = #lines + 1
    table.insert(lines, table.concat(cells, ' '))

    for _, cell in ipairs(cell_data) do
      local severity = deadline_map[cell.day_key]
      local group = calendar_day_group(severity, cell.day_key == today_key)
      if group then
        local col = cell.weekday * 3
        table.insert(highlights, {
          line = week_line_idx,
          start_col = col,
          end_col = col + 2,
          group = group,
        })
      end
    end

    first_weekday = 0
  end

  return {
    lines = lines,
    highlights = highlights,
  }
end

local function compose_calendar_stack(blocks)
  local lines = {}
  local highlights = {}

  for i, block in ipairs(blocks) do
    if i > 1 then
      table.insert(lines, '')
    end

    local base_line = #lines
    for _, line in ipairs(block.lines) do
      table.insert(lines, line)
    end

    for _, highlight in ipairs(block.highlights) do
      table.insert(highlights, {
        line = base_line + highlight.line,
        start_col = highlight.start_col,
        end_col = highlight.end_col,
        group = highlight.group,
      })
    end
  end

  return lines, highlights
end

local function compose_calendar_grid(blocks, columns, gap)
  local lines = {}
  local highlights = {}
  local spacing = string.rep(' ', gap)

  for row_start = 1, #blocks, columns do
    local row_blocks = {}
    for i = row_start, math.min(row_start + columns - 1, #blocks) do
      table.insert(row_blocks, blocks[i])
    end

    if #lines > 0 then
      table.insert(lines, '')
    end

    local widths = {}
    local row_height = 0
    for i, block in ipairs(row_blocks) do
      local block_width = 0
      for _, line in ipairs(block.lines) do
        block_width = math.max(block_width, vim.fn.strdisplaywidth(line))
      end
      widths[i] = block_width
      row_height = math.max(row_height, #block.lines)
    end

    local col_offsets = {}
    local running_col = 0
    for i = 1, #row_blocks do
      col_offsets[i] = running_col
      running_col = running_col + widths[i] + gap
    end

    local row_base_line = #lines
    for line_idx = 1, row_height do
      local parts = {}
      for i, block in ipairs(row_blocks) do
        local block_line = block.lines[line_idx] or ''
        parts[i] = pad_to_display_width(block_line, widths[i])
      end
      table.insert(lines, table.concat(parts, spacing))
    end

    for i, block in ipairs(row_blocks) do
      local col_offset = col_offsets[i]
      for _, highlight in ipairs(block.highlights) do
        table.insert(highlights, {
          line = row_base_line + highlight.line,
          start_col = col_offset + highlight.start_col,
          end_col = col_offset + highlight.end_col,
          group = highlight.group,
        })
      end
    end
  end

  return lines, highlights
end

local function build_calendar_lines(tasks, today, layout_position)
  local calendar_config = config.calendar or {}
  if not calendar_config.enabled then
    return {}, {}
  end

  local months_to_show = tonumber(calendar_config.months_to_show) or 1
  months_to_show = math.max(1, math.floor(months_to_show))
  local layout = layout_position or calendar_config.position or 'top'
  local week_start = normalize_week_start(calendar_config.week_start)

  local today_key = os.date('%Y-%m-%d', today)
  local today_year = tonumber(os.date('%Y', today))
  local today_month = tonumber(os.date('%m', today))
  local deadline_map = build_deadline_map(tasks, today)
  local month_blocks = {}

  for month_offset = 0, months_to_show - 1 do
    local year, month = add_months(today_year, today_month, month_offset)
    table.insert(month_blocks, build_calendar_month_block(year, month, today_key, deadline_map, week_start))
  end

  local body_lines = {}
  local body_highlights = {}
  if layout == 'top' and #month_blocks > 1 then
    local grid_columns = tonumber(calendar_config.grid_columns) or 2
    grid_columns = math.max(1, math.floor(grid_columns))
    body_lines, body_highlights = compose_calendar_grid(month_blocks, grid_columns, 4)
  else
    body_lines, body_highlights = compose_calendar_stack(month_blocks)
  end

  local lines = { 'Calendar' }
  local highlights = {}
  local base_line = #lines

  for _, line in ipairs(body_lines) do
    table.insert(lines, line)
  end

  for _, highlight in ipairs(body_highlights) do
    table.insert(highlights, {
      line = base_line + highlight.line,
      start_col = highlight.start_col,
      end_col = highlight.end_col,
      group = highlight.group,
    })
  end

  return lines, highlights
end

pad_to_display_width = function(text, width)
  local text_width = vim.fn.strdisplaywidth(text)
  if text_width >= width then
    return text
  end

  return text .. string.rep(' ', width - text_width)
end

local function merge_side_by_side(left_lines, right_lines, right_highlights, gap)
  local merged_lines = {}
  local merged_highlights = {}
  local right_offsets = {}
  local left_col_limits = {}

  local left_width = 0
  for _, line in ipairs(left_lines) do
    left_width = math.max(left_width, vim.fn.strdisplaywidth(line))
  end

  local total_lines = math.max(#left_lines, #right_lines)
  local separator = string.rep(' ', gap)

  for i = 1, total_lines do
    local left_line = left_lines[i] or ''
    local right_line = right_lines[i] or ''
    local left_padded = pad_to_display_width(left_line, left_width)

    if #right_lines > 0 then
      right_offsets[i] = #left_padded + gap
      left_col_limits[i] = #left_padded
      table.insert(merged_lines, left_padded .. separator .. right_line)
    else
      table.insert(merged_lines, left_line)
    end
  end

  for _, highlight in ipairs(right_highlights or {}) do
    local col_offset = right_offsets[highlight.line]
    if col_offset then
      table.insert(merged_highlights, {
        line = highlight.line,
        start_col = col_offset + highlight.start_col,
        end_col = col_offset + highlight.end_col,
        group = highlight.group,
      })
    end
  end

  return merged_lines, merged_highlights, left_col_limits
end

local function build_agenda_sections(tasks, today)
  local lines = {}
  local task_map = {}
  local section_lines = {}
  local today_str = format_date(today)
  local week_end = today + (7 * DAY_SECONDS)
  local icons = config.icons

  local today_tasks = {}
  local overdue_tasks = {}
  local week_tasks = {}

  for _, task in ipairs(tasks) do
    local task_date_str = format_date(task.date)
    if task_date_str == today_str then
      table.insert(today_tasks, task)
    elseif task.date < today then
      table.insert(overdue_tasks, task)
    elseif task.date > today and task.date <= week_end then
      table.insert(week_tasks, task)
    end
  end

  local today_icon = state.today_expanded and icons.expanded or icons.collapsed
  local today_count = #today_tasks + #overdue_tasks
  local today_header = string.format('%s  Today (%d tasks)', today_icon, today_count)
  table.insert(lines, today_header)
  section_lines.today_header = #lines

  if state.today_expanded then
    if #overdue_tasks > 0 then
      for _, task in ipairs(overdue_tasks) do
        local prefix = task.is_in_progress and '[-]' or '[ ]'
        local line = string.format('  %s %s: %s %s', icons.overdue, format_date(task.date), task.text, prefix)
        table.insert(lines, line)
        task_map[#lines] = task
      end
    end

    if #today_tasks > 0 then
      for _, task in ipairs(today_tasks) do
        local task_line = format_task_line(task, today)
        table.insert(lines, task_line)
        task_map[#lines] = task
      end
    end

    if #today_tasks == 0 and #overdue_tasks == 0 then
      table.insert(lines, '    No tasks for today')
    end
  end

  table.insert(lines, '')

  local week_icon = state.week_expanded and icons.expanded or icons.collapsed
  local week_header = string.format('%s  This Week (%d tasks)', week_icon, #week_tasks)
  table.insert(lines, week_header)
  section_lines.week_header = #lines

  if state.week_expanded then
    if #week_tasks > 0 then
      local current_date = nil
      for _, task in ipairs(week_tasks) do
        local task_date = format_date(task.date)
        if task_date ~= current_date then
          current_date = task_date
          local display = format_display_date(task.date, today)
          table.insert(lines, '  ' .. display)
        end
        local task_line = format_task_line(task, today)
        table.insert(lines, task_line)
        task_map[#lines] = task
      end
    else
      table.insert(lines, '    No tasks this week')
    end
  end

  if is_help_enabled() then
    table.insert(lines, '')
    if is_help_separator_enabled() then
      table.insert(lines, string.rep('─', 60))
    end
    table.insert(lines, string.format('%s = scheduled  %s ≤1d  %s 2-4d  %s >4d  %s = overdue',
      icons.scheduled, icons.deadline_urgent, icons.deadline_soon, icons.deadline_ok, icons.overdue))
    table.insert(lines, '<Enter> jump  <Tab> toggle section  <Esc>/<q> close')
  end

  return lines, task_map, section_lines
end

local function get_window_size(lines)
  local max_line_width = 0
  for _, line in ipairs(lines) do
    max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(line))
  end

  local min_width = 70
  local calendar_config = config.calendar or {}
  local calendar_position = calendar_config.position or 'top'
  if calendar_config.enabled and calendar_position == 'right' then
    min_width = 95
  end

  local width = math.max(min_width, max_line_width + 4)
  width = math.min(width, math.max(40, vim.o.columns - 4))

  local max_height = math.max(15, math.floor(vim.o.lines * 0.8))
  local height = math.min(#lines, max_height)

  return width, height
end

local function append_lines(target, source)
  local base_line = #target
  for _, line in ipairs(source) do
    table.insert(target, line)
  end
  return base_line
end

local function merge_line_map(target, source, base_line)
  for line_num, value in pairs(source) do
    target[base_line + line_num] = value
  end
end

local function merge_section_lines(target, source, base_line)
  for section_name, line_num in pairs(source) do
    target[section_name] = base_line + line_num
  end
end

local function merge_shifted_highlights(target, source, base_line)
  for _, highlight in ipairs(source) do
    table.insert(target, {
      line = base_line + highlight.line,
      start_col = highlight.start_col,
      end_col = highlight.end_col,
      group = highlight.group,
    })
  end
end

local function apply_buffer_highlights(buf, lines, calendar_highlights, left_col_limits)
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)

  local function add_highlight(group, line_idx, start_col, end_col)
    local limit = left_col_limits and left_col_limits[line_idx]
    local hl_end_col = end_col or -1

    if limit then
      if start_col >= limit then
        return
      end

      if hl_end_col == -1 or hl_end_col > limit then
        hl_end_col = limit
      end
    end

    vim.api.nvim_buf_add_highlight(buf, -1, group, line_idx - 1, start_col, hl_end_col)
  end

  local icons = config.icons
  for i, line in ipairs(lines) do
    if line:match('^📅') or line:match('^─') or line:match('Calendar$') then
      add_highlight('Title', i, 0, -1)
    elseif line:match('^[' .. icons.expanded .. icons.collapsed .. ']') then
      add_highlight('Function', i, 0, -1)
    elseif line:match(icons.overdue) then
      add_highlight('DiagnosticError', i, 0, -1)
    elseif line:match('^  %a') then
      add_highlight('Comment', i, 0, -1)
    elseif line:match(icons.deadline_urgent) then
      add_highlight('DiagnosticWarn', i, 0, -1)
    end

    if left_col_limits and line:match('Calendar$') then
      local right_start = (left_col_limits[i] or 0) + 4
      local calendar_col = line:find('Calendar', right_start, true)
      if calendar_col then
        vim.api.nvim_buf_add_highlight(buf, -1, 'Title', i - 1, calendar_col - 1, calendar_col - 1 + #'Calendar')
      end
    end
  end

  for _, highlight in ipairs(calendar_highlights) do
    if highlight.group then
      vim.api.nvim_buf_add_highlight(buf, -1, highlight.group, highlight.line - 1, highlight.start_col, highlight.end_col)
    end
  end
end

local function scan_files()
  local tasks = {}
  local directory = vim.fn.expand(config.directory)
  local pattern = config.recursive and (directory .. '/**/*.md') or (directory .. '/*.md')
  local files = vim.fn.glob(pattern, false, true)
  local date_pattern = get_date_pattern(config.date_format)

  for _, filepath in ipairs(files) do
    local file = io.open(filepath, 'r')
    if file then
      local line_num = 0
      for line in file:lines() do
        line_num = line_num + 1

        local is_todo = line:match('^%s*%- %[ %]') or line:match('^%s*%- %[%-%]')
        if is_todo then
          local scheduled_pattern = '@scheduled%((' .. date_pattern .. ')%)'
          local deadline_pattern = '@deadline%((' .. date_pattern .. ')%)'
          local scheduled = line:match(scheduled_pattern)
          local deadline = line:match(deadline_pattern)

          if scheduled or deadline then
            local task_text = line:gsub('^%s*%- %[.%]%s*', ''):gsub('%s*@scheduled%([^)]+%)', ''):gsub('%s*@deadline%([^)]+%)', '')
            task_text = vim.trim(task_text)

            local task = {
              text = task_text,
              scheduled = scheduled,
              deadline = deadline,
              deadline_ts = deadline and parse_date(deadline, config.date_format) or nil,
              filepath = filepath,
              line = line_num,
              is_in_progress = line:match('^%s*%- %[%-%]') ~= nil,
            }

            if scheduled then
              local ts = parse_date(scheduled, config.date_format)
              if ts then
                table.insert(tasks, vim.tbl_extend('force', task, { date = ts, date_type = 'scheduled' }))
              end
            end

            if deadline then
              local ts = parse_date(deadline, config.date_format)
              if ts then
                if not scheduled or scheduled ~= deadline then
                  table.insert(tasks, vim.tbl_extend('force', task, { date = ts, date_type = 'deadline' }))
                else
                  tasks[#tasks].date_type = 'both'
                end
              end
            end
          end
        end
      end
      file:close()
    end
  end

  table.sort(tasks, function(a, b) return a.date < b.date end)
  return tasks
end

format_task_line = function(task, today)
  local prefix = task.is_in_progress and '    [-] ' or '    [ ] '
  local suffix = ''
  local icons = config.icons

  if task.date_type == 'scheduled' then
    suffix = ' ' .. icons.scheduled
  else
    local severity, days_left = get_deadline_severity(task.deadline_ts, today)
    local urgency_icon = deadline_icon_for_severity(severity)

    local days_text
    if days_left < 0 then
      days_text = string.format('%d days overdue', -days_left)
    elseif days_left == 0 then
      days_text = 'today'
    elseif days_left == 1 then
      days_text = '1 day left'
    else
      days_text = string.format('%d days left', days_left)
    end

    if task.date_type == 'both' then
      suffix = string.format(' %s %s %s', icons.scheduled, urgency_icon, days_text)
    else
      suffix = string.format(' %s %s', urgency_icon, days_text)
    end
  end

  return prefix .. task.text .. suffix
end

local function build_agenda_lines(tasks)
  local lines = {}
  local task_map = {}
  local section_lines = {}
  local calendar_highlights = {}
  local left_col_limits = {}
  local today = get_today_timestamp()
  local agenda_lines, agenda_task_map, agenda_section_lines = build_agenda_sections(tasks, today)

  local function append_agenda_content()
    local base_line = append_lines(lines, agenda_lines)
    merge_line_map(task_map, agenda_task_map, base_line)
    merge_section_lines(section_lines, agenda_section_lines, base_line)
  end

  table.insert(lines, '📅 Agenda')
  if is_header_separator_enabled() then
    table.insert(lines, string.rep('─', 60))
  end
  table.insert(lines, '')

  local calendar_config = config.calendar or {}
  local calendar_position = calendar_config.position or 'top'
  if calendar_config.enabled and calendar_position == 'top' then
    local calendar_lines, relative_calendar_highlights = build_calendar_lines(tasks, today, 'top')
    if #calendar_lines > 0 then
      local base_line = append_lines(lines, calendar_lines)
      merge_shifted_highlights(calendar_highlights, relative_calendar_highlights, base_line)

      table.insert(lines, '')
    end

    append_agenda_content()
  elseif calendar_config.enabled and calendar_position == 'right' then
    local calendar_lines, relative_calendar_highlights = build_calendar_lines(tasks, today, 'right')
    local merged_lines, merged_calendar_highlights, merged_left_col_limits = merge_side_by_side(agenda_lines, calendar_lines, relative_calendar_highlights, 4)
    local base_line = append_lines(lines, merged_lines)
    merge_line_map(task_map, agenda_task_map, base_line)
    merge_section_lines(section_lines, agenda_section_lines, base_line)
    merge_shifted_highlights(calendar_highlights, merged_calendar_highlights, base_line)

    for line_num, col_limit in pairs(merged_left_col_limits) do
      left_col_limits[base_line + line_num] = col_limit
    end
  else
    append_agenda_content()
  end

  return lines, task_map, section_lines, calendar_highlights, left_col_limits
end

local function refresh_agenda(buf, win)
  local tasks = scan_files()
  local lines, task_map, section_lines, calendar_highlights, left_col_limits = build_agenda_lines(tasks)

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  local width, height = get_window_size(lines)
  vim.api.nvim_win_set_width(win, width)
  vim.api.nvim_win_set_height(win, height)

  apply_buffer_highlights(buf, lines, calendar_highlights, left_col_limits)

  return task_map, section_lines
end

function M.open()
  local tasks = scan_files()
  local lines, task_map, section_lines, calendar_highlights, left_col_limits = build_agenda_lines(tasks)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'markdown-agenda', { buf = buf })

  local width, height = get_window_size(lines)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local window_title = get_window_title()

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = get_window_border(),
    title = window_title,
    title_pos = window_title and get_window_title_pos() or nil,
  })

  vim.api.nvim_set_option_value('cursorline', true, { win = win })
  vim.api.nvim_set_option_value('wrap', false, { win = win })

  local current_task_map = task_map
  local current_section_lines = section_lines

  vim.keymap.set('n', '<Esc>', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  vim.keymap.set('n', 'q', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  vim.keymap.set('n', '<CR>', function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local line_num = cursor[1]
    local task = current_task_map[line_num]

    if task then
      vim.api.nvim_win_close(win, true)
      vim.cmd('edit ' .. vim.fn.fnameescape(task.filepath))
      vim.api.nvim_win_set_cursor(0, { task.line, 0 })
      vim.cmd('normal! zz')
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set('n', '<Tab>', function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local line_num = cursor[1]

    if line_num == current_section_lines.today_header then
      state.today_expanded = not state.today_expanded
      current_task_map, current_section_lines = refresh_agenda(buf, win)
    elseif line_num == current_section_lines.week_header then
      state.week_expanded = not state.week_expanded
      current_task_map, current_section_lines = refresh_agenda(buf, win)
    end
  end, { buffer = buf, nowait = true })

  apply_buffer_highlights(buf, lines, calendar_highlights, left_col_limits)
end

function M.setup(opts)
  local normalized_opts = vim.deepcopy(opts or {})

  if normalized_opts.header_separator == nil and normalized_opts.separator ~= nil then
    normalized_opts.header_separator = normalized_opts.separator
  end

  if normalized_opts.header_separator == nil and normalized_opts.help == false and normalized_opts.help_separator ~= nil then
    normalized_opts.header_separator = normalized_opts.help_separator
  end

  if normalized_opts.hide ~= nil and normalized_opts.help == nil then
    normalized_opts.help = not normalized_opts.hide
  end

  if normalized_opts.show_help ~= nil and normalized_opts.help == nil then
    normalized_opts.help = normalized_opts.show_help
  end

  config = vim.tbl_deep_extend('force', defaults, normalized_opts)

  vim.api.nvim_create_user_command('MarkdownAgenda', function()
    M.open()
  end, { desc = 'Open Markdown Agenda' })

  if config.keymaps.open then
    vim.keymap.set('n', config.keymaps.open, function()
      M.open()
    end, { desc = 'Open Markdown Agenda' })
  end
end

return M
