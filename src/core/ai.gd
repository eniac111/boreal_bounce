class_name Ai
extends RefCounted
## A simple computer player: predicts where a shot at a given angle lands (same movement rules
## as Sim: 10 px/frame, wall reflection, ceiling and 26.24 px collision) and picks the angle
## whose landing pops the biggest group, else the one landing highest. Used to drive demo
## recordings and available for a future "computer opponent".

const ANGLE_STEP := 0.02


## Cell where a shot fired now at [param angle] would land, or (-1,-1) if none within 400 frames.
static func landing_cell(p: Playfield, angle: float) -> Vector2i:
	var pos := p.launch_pos()
	var x := pos.x
	var y := pos.y
	var dir := angle
	var threshold := (p.bubble_size * Rules.COLLISION_FACTOR) ** 2
	var right_edge := p.right_limit - p.bubble_size
	for i in 400:
		var x_old := x
		var y_old := y
		x += Rules.BUBBLE_SPEED * cos(dir)
		y -= Rules.BUBBLE_SPEED * sin(dir)
		if x < p.left_limit:
			x = 2.0 * p.left_limit - x
			dir = PI - dir
		if x > right_edge:
			x = 2.0 * right_edge - x
			dir = PI - dir
		if y <= p.ceiling_y():
			return p.pixel_to_cell(x, y)
		for cy in p.grid.rows.size():
			var row := p.grid.rows[cy]
			for cx in row.size():
				if row[cx] == Playfield.EMPTY:
					continue
				var c := p.cell_to_pixel(cx, cy)
				var dx := x - c.x
				var dy := y - c.y
				if dx * dx + dy * dy < threshold:
					return p.pixel_to_cell((x_old + x) / 2.0, (y_old + y) / 2.0)
	return Vector2i(-1, -1)


## Best angle for the colour currently in the cannon.
static func best_angle(p: Playfield) -> float:
	var colour := p.launcher_colour
	var best := PI / 2
	var best_score := -INF
	var a := Rules.ANGLE_MIN
	while a <= Rules.ANGLE_MAX:
		var cell := landing_cell(p, a)
		if cell.x >= 0 and p.grid.in_bounds(cell.x, cell.y) and p.grid.is_empty(cell.x, cell.y):
			# evaluate the landing without leaving a trace (rows created on demand are dropped
			# again, otherwise the board state would differ between network peers)
			var rows_before := p.grid.rows.size()
			p.grid.set_cell(cell.x, cell.y, colour)
			var group := p.grid.group_of(cell.x, cell.y).size()
			var orphans := p.grid.orphans(p.newrootlevel).size() if group >= 3 else 0
			p.grid.set_cell(cell.x, cell.y, Playfield.EMPTY)
			p.grid.rows.resize(rows_before)
			var score := 0.0
			if group >= 3:
				score = 100.0 + group * 10.0 + orphans * 5.0
			else:
				score = -cell.y * 2.0 + group * 1.0  # stick high, next to a same colour if possible
			score -= absf(a - p.angle) * 0.5  # prefer nearby aims a little
			if score > best_score:
				best_score = score
				best = a
		a += ANGLE_STEP
	return best


## Keys to press this frame to reach [param target] and fire when aligned.
static func inputs_towards(p: Playfield, target: float) -> Dictionary:
	var diff := target - p.angle
	if absf(diff) <= Rules.LAUNCHER_SPEED * 0.75:
		return {"fire": true}
	return {"left": diff > 0.0, "right": diff < 0.0}
